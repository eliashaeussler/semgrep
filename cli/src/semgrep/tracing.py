# Library to use Opentelemetry traces and logs from the python side of Semgrep
#
# Enables sending traces and logs, currently to Datadog, Jaeger, both with 15
# days retention policy
#
# Communicates with OCaml tracing defined in ../../../libs/tracing/unix/Tracing.ml
# For more info, see https://www.notion.so/semgrep/How-to-add-tracing-b0e1eaa1531e408cbb074663d1f840a6
import functools
import logging
import os
from typing import Callable
from typing import Optional
from typing import TypeVar

from attr import define
from opentelemetry import context
from opentelemetry import propagate
from opentelemetry import trace as otrace
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.sdk._logs import LoggerProvider
from opentelemetry.sdk._logs import LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import get_aggregated_resources
from opentelemetry.sdk.resources import OTELResourceDetector
from opentelemetry.sdk.resources import ProcessResourceDetector
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.resources import SERVICE_NAME
from opentelemetry.sdk.resources import SERVICE_VERSION
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from typing_extensions import ParamSpec

from semgrep import __VERSION__

TRACER = otrace.get_tracer(__name__)

# Coupling: these constants need to be kept in sync with Tracing.ml

_SEMGREP_TRACE_PARENT_TRACE_ID = "SEMGREP_TRACE_PARENT_TRACE_ID"
_SEMGREP_TRACE_PARENT_SPAN_ID = "SEMGREP_TRACE_PARENT_SPAN_ID"

_DEFAULT_ENDPOINT = "https://telemetry.semgrep.dev"
_DEV_ENDPOINT = "https://telemetry.dev2.semgrep.dev"
_LOCAL_ENDPOINT = "http://localhost:4318"

_ENDPOINT_ALIASES = {
    "semgrep-prod": _DEFAULT_ENDPOINT,
    "semgrep-dev": _DEV_ENDPOINT,
    "semgrep-local": _LOCAL_ENDPOINT,
}

_ENV_ALIASES = {
    "semgrep-prod": "prod",
    "semgrep-dev": "dev2",
    "semgrep-local": "local",
}


@define
class Traces:
    enabled: bool = False

    def configure(self, enabled: bool, trace_endpoint: Optional[str]) -> None:
        self.enabled = enabled

        if not self.enabled:
            return

        env_name = _ENV_ALIASES.get(
            _DEFAULT_ENDPOINT if trace_endpoint is None else trace_endpoint
        )
        resource = get_aggregated_resources(
            detectors=[ProcessResourceDetector(), OTELResourceDetector()],  # type: ignore
            initial_resource=Resource(
                attributes={
                    SERVICE_NAME: "semgrep-cli",
                    SERVICE_VERSION: __VERSION__,
                    "deployment.environment.name": env_name if env_name else "prod",
                },
            ),
        )

        tracer_provider = TracerProvider(resource=resource)
        logger_provider = LoggerProvider(resource=resource)

        set_logger_provider(logger_provider)
        otrace.set_tracer_provider(tracer_provider)

        endpoint = (
            _ENDPOINT_ALIASES.get(trace_endpoint, trace_endpoint)
            if trace_endpoint
            else _DEFAULT_ENDPOINT
        )
        # See https://opentelemetry.io/docs/languages/sdk-configuration/otlp-exporter/#otel_exporter_otlp_endpoint
        # for specs on this
        exporter_spans = OTLPSpanExporter(endpoint + "/v1/traces")
        exporter_logs = OTLPLogExporter(endpoint + "/v1/logs")

        span_processor = BatchSpanProcessor(exporter_spans)
        log_processor = BatchLogRecordProcessor(exporter_logs)

        tracer_provider.add_span_processor(span_processor)
        logger_provider.add_log_record_processor(log_processor)

        # add logging handler so we can send logs to Otel and therefore datadog
        logging_handler = LoggingHandler(
            # COUPLING: we do something similar in Tracing.ml. If we want to
            # enable sending debug logs here we probably want to send them from
            # semgrep-core too!
            level=logging.INFO,
            logger_provider=logger_provider,
        )
        logging.getLogger().addHandler(logging_handler)
        # get all existing loggers and add the handler to them, since at this
        # point we will have already set up loggers most/all places NOTE: we
        # don't set this up beforehand because we need to parse which
        # environment we're in and then set the resource attributes before we
        # can setup the logging handler
        for logger in logging.Logger.manager.loggerDict.values():
            if isinstance(logger, logging.Logger):
                logger.addHandler(logging_handler)

        RequestsInstrumentor().instrument()
        self.extract()

    def extract(self) -> None:
        trace_id = os.getenv(_SEMGREP_TRACE_PARENT_TRACE_ID)
        span_id = os.getenv(_SEMGREP_TRACE_PARENT_SPAN_ID)
        if trace_id and span_id:
            trace_flags = 1
            # W3C Trace Context spec: https://www.w3.org/TR/trace-context/#version-format
            carrier = {"traceparent": f"00-{trace_id}-{span_id}-{trace_flags:02x}"}
            extracted_context = propagate.extract(carrier, context.get_current())
            context.attach(extracted_context)

    def inject(self) -> None:
        if not self.enabled:
            return

        current_span = otrace.get_current_span()
        current_context = current_span.get_span_context()
        os.environ[_SEMGREP_TRACE_PARENT_TRACE_ID] = otrace.format_trace_id(
            current_context.trace_id
        )
        os.environ[_SEMGREP_TRACE_PARENT_SPAN_ID] = otrace.format_span_id(
            current_context.span_id
        )


P = ParamSpec("P")
R = TypeVar("R")


def trace() -> Callable[[Callable[P, R]], Callable[P, R]]:
    def outer(f: Callable[P, R]) -> Callable[P, R]:
        span_name = f"{f.__module__}.{f.__name__}"

        @functools.wraps(f)
        def inner(*args: P.args, **kwargs: P.kwargs) -> R:
            with TRACER.start_as_current_span(span_name):
                return f(*args, **kwargs)

        return inner

    return outer
