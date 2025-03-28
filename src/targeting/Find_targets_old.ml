open Common
open Fpath_.Operators
module In = Input_to_core_t
module OutJ = Semgrep_output_v1_t
module Resp = Semgrep_output_v1_t
open Find_targets (* conf type *)
module Log = Log_targeting.Log

(*************************************************************************)
(* Prelude *)
(*************************************************************************)
(* Deprecated: use Find_targets.ml instead. *)

(*************************************************************************)
(* Dedup *)
(*************************************************************************)

(* TODO? use Common2.uniq_eff *)
let deduplicate_list l =
  let tbl = Hashtbl.create 1000 in
  List.filter
    (fun x ->
      if Hashtbl.mem tbl x then false
      else (
        Hashtbl.add tbl x ();
        true))
    l

(*************************************************************************)
(* Sorting *)
(*************************************************************************)

(* similar to Run_semgrep.sort_targets_by_decreasing_size, could factorize *)
let sort_files_by_decreasing_size files =
  files
  |> List_.map (fun file -> (file, UFile.filesize file))
  |> List.sort (fun (_, (a : int)) (_, b) -> compare b a)
  |> List_.map fst

(*************************************************************************)
(* Filtering *)
(*************************************************************************)

(*
   Filter files can make suitable targets, independently from specific
   rules or languages.

   'sort_by_decr_size' should always be true but we keep it as an option
   for compatibility with the legacy implementation 'files_of_dirs_or_files'.

   '?lang' is a legacy option that shouldn't be used in
   the language-independent 'select_global_targets'.
*)
let global_filter ~opt_lang ~sort_by_decr_size paths =
  let paths, skipped1 = Skip_target.exclude_inaccessible_files paths in
  let paths, skipped2 =
    match opt_lang with
    | None -> (paths, [])
    | Some lang -> Guess_lang.inspect_files lang paths
  in
  let paths, skipped3 =
    Skip_target.exclude_big_files !Flag_semgrep.max_target_bytes paths
  in
  let paths, skipped4 = Skip_target.exclude_minified_files paths in
  let skipped = List_.flatten [ skipped1; skipped2; skipped3; skipped4 ] in
  let sorted_paths =
    if sort_by_decr_size then sort_files_by_decreasing_size paths else paths
  in
  let sorted_skipped =
    List.sort
      (fun (a : OutJ.skipped_target) b -> Fpath.compare a.path b.path)
      skipped
  in
  (sorted_paths, sorted_skipped)
[@@profiling]

(*************************************************************************)
(* Grouping (old) *)
(*************************************************************************)

(*
   func must return:
     ((project_kind, project_root), path)
*)
let group_by_project_root func paths =
  List_.map func paths |> Assoc.group_by fst
  |> List_.map (fun (k, kv_list) -> (k, List_.map snd kv_list))

(*
   Identify the project root for each scanning root and group them
   by project root. If the project_root is specified, then we use that.

   This is important to avoid reading the gitignore and semgrepignore files
   twice when multiple scanning roots that belong to the same project.

   LATER: use Ppaths rather than full paths as scanning roots
   when we switch to Semgrepignore.list to list project files.

   TODO? move in paths/Project.ml?
*)
let group_roots_by_project conf (paths : Scanning_root.t list) =
  let force_root : Project.t option =
    match conf.force_project_root with
    | Some (Find_targets.Git_remote _)
    | None ->
        None
    | Some (Find_targets.Filesystem proj_root) ->
        Some Project.{ kind = Project.Git_project; root = proj_root }
  in
  if conf.respect_gitignore then
    paths
    |> group_by_project_root (fun (path : Scanning_root.t) ->
           let ( kind,
                 ({ project_root = root; inproject_path = git_path } :
                   Project.scanning_root_info) ) =
             Project.find_any_project_root ?force_root
               (Scanning_root.to_fpath path)
           in
           ((kind, root), Ppath.to_fpath ~root:(Rfpath.to_fpath root) git_path))
  else
    (* ignore gitignore files but respect semgrepignore files *)
    paths
    |> group_by_project_root (fun (path : Scanning_root.t) ->
           let ({ project_root = root; inproject_path = git_path }
                 : Project.scanning_root_info) =
             Project.force_project_root (Scanning_root.to_fpath path)
           in
           ( (Project.Other_project, root),
             Ppath.to_fpath ~root:(Rfpath.to_fpath root) git_path ))

(*************************************************************************)
(* Finding (old) *)
(*************************************************************************)

(* Check if file is a readable regular file.

   This eliminates files that should never be semgrep targets. Among
   others, this takes care of excluding symbolic links (because we don't
   want to scan the target twice), directories (which may be returned by
   globbing or by 'git ls-files' e.g. submodules), and
   TODO files missing the read permission.

   bugfix: we were using Common2.is_file but it is throwing an exn when a
   file does exist
   (which could happen when a file tracked by git was deleted, in which
   case files_from_git_ls() below would still return it but Common2.is_file()
   would fail).

   TODO: we could return a skipped_target if the valid is not valid, adding
   a new Unreadable_file and Inexistent_file to semgrep_output_v1.atd
   skip_reason type.
*)
let is_valid_file file =
  (* TOPORT: return self._is_valid_file_or_dir(path) and path.is_file() *)
  try
    let stat = Unix.stat !!file in
    stat.Unix.st_kind =*= Unix.S_REG
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> false

(* python: 'git ls-files' is significantly faster than os.walk when performed
 * on a git project, so identify the git files first, then filter those later.
 *)
let files_from_git_ls ~cwd:scan_root =
  (* TOPORT:
      # Untracked but not ignored files
      untracked_output = run_git_command([
              "git",
              "ls-files",
              "--other",
              "--exclude-standard",
          ])
      deleted_output = run_git_command(["git", "ls-files", "--deleted"])
      tracked = self._parse_git_output(tracked_output)
      untracked_unignored = self._parse_git_output(untracked_output)
      deleted = self._parse_git_output(deleted_output)
      return frozenset(tracked | untracked_unignored - deleted)
  *)
  (* tracked files *)
  let tracked_output = Git_wrapper.ls_files ~cwd:scan_root [] in
  tracked_output
  |> List_.map (fun x -> if !!scan_root = "." then x else scan_root // x)
  |> List.filter is_valid_file
[@@profiling]

(* python: mostly Target.files() method in target_manager.py *)
let list_regular_files (conf : conf) (scan_root : Fpath.t) : Fpath.t list =
  (* This may raise Unix.Unix_error.
   * better: Note that I use Unix.stat below, not Unix.lstat, so we can
   * actually analyze symlink to dirs!
   * TODO? improve Unix.Unix_error in Find_targets specific exn?
   *)
  match (Unix.stat !!scan_root).st_kind with
  (* TOPORT? make sure has right permissions (readable) *)
  | S_REG -> [ scan_root ]
  | S_DIR ->
      (* LATER: maybe we should first check whether scan_root is inside
       * a git repository because respect_git_ignore is set to true by default
       * and so it does not really mean the user want to use git (and
       * a possible .gitignore) to list files.
       *)
      if conf.respect_gitignore then (
        try files_from_git_ls ~cwd:scan_root with
        | (Git_wrapper.Error _ | Unix.Unix_error _) as exn ->
            (* nosemgrep: no-logs-in-library *)
            Logs.info (fun m ->
                m
                  "Unable to ignore files ignored by git (%s is not a git \
                   directory or git is not installed). Running on all files \
                   instead..."
                  !!scan_root);
            Log.err (fun m -> m "exn = %s" (Common.exn_to_s exn));
            List_files.list_regular_files ~keep_root:true scan_root)
      else
        (* python: was called Target.files_from_filesystem () *)
        List_files.list_regular_files ~keep_root:true scan_root
  | S_LNK ->
      (* already dereferenced by Unix.stat *)
      assert false
  (* TODO? use write_pipe_to_disk? *)
  | S_FIFO -> []
  | S_CHR
  | S_BLK
  | S_SOCK ->
      []
[@@profiling]

(*************************************************************************)
(* Entry point (old) *)
(*************************************************************************)

(* python: mix of Target_manager(), target_manager.get_files_for_rule(),
   target_manager.get_all_files(), Target(), and Target.files()

   This takes a list of scanning roots which are either regular files
   or directories. Directories are scanned and we return files discovered
   in this directories.

   See the documentation for the conf object for the various filters
   that we apply.
*)
let get_targets conf (scanning_roots : Scanning_root.t list) =
  (* python: =~ Target_manager.get_all_files() *)
  group_roots_by_project conf scanning_roots
  |> List_.map (fun ((proj_kind, project_root), scanning_roots) ->
         (* step0: starting point (git ls-files or List_files) *)
         let paths =
           scanning_roots
           |> List.concat_map (fun scan_root ->
                  list_regular_files conf scan_root)
           |> deduplicate_list
         in

         (* step1: filter with .gitignore and .semgrepignore *)
         let exclusion_mechanism : Semgrepignore.exclusion_mechanism =
           match (proj_kind : Project.kind) with
           | Git_project
           | Gitignore_project ->
               { use_gitignore_files = true; use_semgrepignore_files = true }
           | Mercurial_project
           | Subversion_project
           | Darcs_project
           | Other_project ->
               { use_gitignore_files = false; use_semgrepignore_files = true }
         in
         let ign =
           Semgrepignore.create ~cli_patterns:conf.exclude
             ~builtin_semgrepignore:Empty ~exclusion_mechanism
             ~project_root:(Rfpath.to_fpath project_root)
             ()
         in
         let include_filter =
           Option.map
             (Include_filter.create
                ~project_root:(Rfpath.to_fpath project_root))
             conf.include_
         in
         let paths, skipped_paths1 =
           paths
           |> Either_.partition (fun path ->
                  Log.info (fun m -> m "Considering path %s" !!path);
                  let rel_path =
                    match
                      Fpath.relativize ~root:(Rfpath.to_fpath project_root) path
                    with
                    | Some x -> x
                    | None ->
                        (* we're supposed to be working with clean paths by now *)
                        assert false
                  in
                  let ppath = Ppath.of_relative_fpath rel_path in
                  let status, selection_events =
                    Gitignore_filter.select ign ppath
                  in
                  let status, selection_events =
                    match status with
                    | Gitignore.Ignored -> (status, selection_events)
                    | Gitignore.Not_ignored -> (
                        match include_filter with
                        | None -> (status, selection_events)
                        | Some include_filter ->
                            let status, more_selection_events =
                              Include_filter.select include_filter ppath
                            in
                            (status, more_selection_events @ selection_events))
                  in
                  match status with
                  | Not_ignored -> Left path
                  | Ignored ->
                      Log.info (fun m ->
                          m "Ignoring path %s:\n%s" !!path
                            (Gitignore.show_selection_events selection_events));
                      let reason =
                        Find_targets.get_reason_for_exclusion selection_events
                      in
                      let skipped =
                        {
                          Resp.path;
                          reason;
                          details =
                            Some
                              "excluded by --include/--exclude, gitignore, or \
                               semgrepignore";
                          rule_id = None;
                        }
                      in
                      Right skipped)
         in
         (* step2: other filters (big files, minified files) *)
         let paths, skipped_paths2 =
           global_filter ~opt_lang:None ~sort_by_decr_size:true paths
         in
         (* step3: filter big files (again).
          * TODO: factorize with Skip_target.exlude_big_files which
          * uses Flag_semgrep.max_target_bytes instead of the osemgrep CLI
          * --max-target-bytes flag.
          *)
         let paths, skipped_paths3 =
           paths
           |> Result_.partition (fun path ->
                  let size = UFile.filesize path in
                  if conf.max_target_bytes > 0 && size > conf.max_target_bytes
                  then
                    Error
                      {
                        Resp.path;
                        reason = Too_big;
                        details =
                          Some
                            (spf "target file size exceeds %i bytes at %i bytes"
                               conf.max_target_bytes size);
                        rule_id = None;
                      }
                  else Ok path)
         in

         (* TODO: respect_git_ignore, baseline_handler, etc. *)
         (paths, skipped_paths1 @ skipped_paths2 @ skipped_paths3))
  |> (* flatten results that were grouped by project *)
  List_.split
  |> fun (paths_list, skipped_paths_list) ->
  (List_.flatten paths_list, List_.flatten skipped_paths_list)
[@@profiling]

(*************************************************************************)
(* Legacy *)
(*************************************************************************)

(* Legacy semgrep-core implementation, used when receiving targets from
   the Python wrapper. *)
let files_of_dirs_or_files ?(keep_root_files = true)
    ?(sort_by_decr_size = false) opt_lang roots =
  let explicit_targets, paths =
    if keep_root_files then
      roots
      |> List.partition (fun path ->
             Sys.file_exists !!path && not (Sys.is_directory !!path))
    else (roots, [])
  in
  let paths = UFile.files_of_dirs_or_files_no_vcs_nofilter paths in

  let paths, skipped = global_filter ~opt_lang ~sort_by_decr_size paths in
  let paths = explicit_targets @ paths in
  let sorted_paths =
    if sort_by_decr_size then sort_files_by_decreasing_size paths
    else List.sort Fpath.compare paths
  in
  let sorted_skipped =
    List.sort
      (fun (a : OutJ.skipped_target) b -> Fpath.compare a.path b.path)
      skipped
  in
  (sorted_paths, sorted_skipped)
