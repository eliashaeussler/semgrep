(* python: was in constants.py, but those are type defs, not constants ...
 * The constructors are repeated so we can use Output_format.Text instead
 * of having to refactor the OCaml code to use Semgrep_output_v1_t.Text.
 *)
type t = Semgrep_output_v1_t.output_format =
  | Text
  | Json
  | Emacs
  | Vim
  | Sarif
  | Gitlab_sast
  | Gitlab_secrets
  | Junit_xml
  (* osemgrep-only *)
  | Files_with_matches
  (* used to disable the final display of match results because
   * we displayed them incrementally instead
   *)
  | Incremental
[@@deriving show]

let keep_ignores (format : t) =
  match format with
  | Sarif -> true
  | Text
  | Json
  | Emacs
  | Vim
  | Gitlab_sast
  | Gitlab_secrets
  | Junit_xml
  | Files_with_matches
  | Incremental ->
      false
