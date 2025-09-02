/**
 * @file etch_perfetto.cpp
 *
 * @brief C++ implementation of Perfetto wrapper for Etch profiling
 */

#include "etch_perfetto.h"

#if ETCH_ENABLE_PERFETTO

#include <string_view>
#include <filesystem>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <thread>
#include <vector>

// Include Perfetto SDK headers
#include "perfetto.h"

// Use the TrackEvent API for tracing
PERFETTO_DEFINE_CATEGORIES(
    perfetto::Category("vm")
        .SetDescription("Etch VM operations"),
    perfetto::Category("function")
        .SetDescription("Function calls and execution"),
    perfetto::Category("instruction")
        .SetDescription("Individual instruction execution"),
    perfetto::Category("gc")
        .SetDescription("Garbage collection operations"),
    perfetto::Category("memory")
        .SetDescription("Memory management operations")
);

PERFETTO_TRACK_EVENT_STATIC_STORAGE();

static bool g_perfetto_initialized = false;
static std::unique_ptr<perfetto::TracingSession> g_tracing_session;

#ifdef __cplusplus
extern "C" {
#endif

bool etch_perfetto_init(const char* process_name, const char* output_file) {
    if (g_perfetto_initialized) {
        return true; // Already initialized
    }

    // Initialize Perfetto
    perfetto::TracingInitArgs args;
    args.backends |= perfetto::kInProcessBackend; // Use in-process backend for simplicity

    perfetto::Tracing::Initialize(args);
    perfetto::TrackEvent::Register();

    // Configure data source
    perfetto::protos::gen::TrackEventConfig track_event_cfg;
    track_event_cfg.add_disabled_categories("*"); // Disable all by default
    track_event_cfg.add_enabled_categories("vm");
    track_event_cfg.add_enabled_categories("function");
    track_event_cfg.add_enabled_categories("instruction");
    track_event_cfg.add_enabled_categories("gc");
    track_event_cfg.add_enabled_categories("memory");

    perfetto::TraceConfig cfg;
    cfg.add_buffers()->set_size_kb(1024); // 1MB buffer
    cfg.set_duration_ms(0); // Continuous tracing
    auto* ds_cfg = cfg.add_data_sources()->mutable_config();
    ds_cfg->set_name("track_event");
    ds_cfg->set_track_event_config_raw(track_event_cfg.SerializeAsString());

    // Set output file if provided
    if (output_file) {
        cfg.set_output_path(output_file);
    }

    // Start tracing session
    g_tracing_session = perfetto::Tracing::NewTrace();
    g_tracing_session->Setup(cfg);
    g_tracing_session->StartBlocking();

    g_perfetto_initialized = true;
    return true;
}

void etch_perfetto_shutdown(void) {
    if (!g_perfetto_initialized) {
        return;
    }

    if (g_tracing_session) {
        g_tracing_session->StopBlocking();

    	std::vector<char> traceData(g_tracing_session->ReadTraceBlocking());

	    std::filesystem::path fileName;
        //if (g_tracing_session->GetTraceConfig().has_output_path()) {
        //    fileName = g_tracing_session->GetTraceConfig().output_path();
        //} else
        {
            fileName = std::filesystem::current_path();
            fileName /= "etch-profile-";
#if NDEBUG
        	fileName += "release-";
#else
    	    fileName += "debug-";
#endif
            fileName += [] {
                auto t = std::time(nullptr);
                auto tm = *std::localtime(&t);
                std::ostringstream oss;
                oss << std::put_time(&tm, "%Y%m%d%H%M%S");
                return oss.str();
            }();
            fileName += ".pftrace";
        }

        auto outputFile = std::ofstream(fileName, std::ios::out | std::ios::binary);
        if (outputFile.is_open()) {
            outputFile.write(traceData.data(), traceData.size());
            outputFile.close();
        }

        g_tracing_session.reset();
    }

    g_perfetto_initialized = false;
}

bool etch_perfetto_is_enabled(void) {
    return g_perfetto_initialized && g_tracing_session != nullptr;
}

void etch_perfetto_begin_event(const char* category, const char* name, uint64_t id) {
    if (!etch_perfetto_is_enabled()) {
        return;
    }

    auto cat = std::string_view(category != nullptr ? category : "vm");
    if (cat == "vm") {
        TRACE_EVENT_BEGIN("vm", perfetto::DynamicString(name), "id", id);
    } else if (cat == "function") {
        TRACE_EVENT_BEGIN("function", perfetto::DynamicString(name), "id", id);
    } else if (cat == "instruction") {
        TRACE_EVENT_BEGIN("instruction", perfetto::DynamicString(name), "id", id);
    } else if (cat == "gc") {
        TRACE_EVENT_BEGIN("gc", perfetto::DynamicString(name), "id", id);
    } else if (cat == "memory") {
        TRACE_EVENT_BEGIN("memory", perfetto::DynamicString(name), "id", id);
    }
}

void etch_perfetto_end_event(const char* category, const char* name, uint64_t id) {
    if (!etch_perfetto_is_enabled()) {
        return;
    }

    auto cat = std::string_view(category != nullptr ? category : "vm");
    if (cat == "vm") {
        TRACE_EVENT_END("vm");
    } else if (cat == "function") {
        TRACE_EVENT_END("function");
    } else if (cat == "instruction") {
        TRACE_EVENT_END("instruction");
    } else if (cat == "gc") {
        TRACE_EVENT_END("gc");
    } else if (cat == "memory") {
        TRACE_EVENT_END("memory");
    }
}

void etch_perfetto_instant_event(const char* category, const char* name, const char* scope) {
    if (!etch_perfetto_is_enabled()) {
        return;
    }

    char scope_char = 't';
    auto scp = std::string_view(scope != nullptr ? scope : "thread");
    if (scp == "global") {
        scope_char = 'g';
    } else if (scp == "process") {
        scope_char = 'p';
    }

    auto cat = std::string_view(category != nullptr ? category : "vm");
    if (cat == "vm") {
        TRACE_EVENT_INSTANT("vm", perfetto::DynamicString(name));
    } else if (cat == "function") {
        TRACE_EVENT_INSTANT("function", perfetto::DynamicString(name));
    } else if (cat == "instruction") {
        TRACE_EVENT_INSTANT("instruction", perfetto::DynamicString(name));
    } else if (cat == "gc") {
        TRACE_EVENT_INSTANT("gc", perfetto::DynamicString(name));
    } else if (cat == "memory") {
        TRACE_EVENT_INSTANT("memory", perfetto::DynamicString(name));
    }
}

void etch_perfetto_counter(const char* category, const char* name, int64_t value, const char* unit) {
    if (!etch_perfetto_is_enabled()) {
        return;
    }

    auto cat = std::string_view(category != nullptr ? category : "vm");
    if (cat == "vm") {
        TRACE_COUNTER("vm", perfetto::DynamicString(name), value);
    } else if (cat == "function") {
        TRACE_COUNTER("function", perfetto::DynamicString(name), value);
    } else if (cat == "instruction") {
        TRACE_COUNTER("instruction", perfetto::DynamicString(name), value);
    } else if (cat == "gc") {
        TRACE_COUNTER("gc", perfetto::DynamicString(name), value);
    } else if (cat == "memory") {
        TRACE_COUNTER("memory", perfetto::DynamicString(name), value);
    }
}

void etch_perfetto_flush(void) {
    if (!etch_perfetto_is_enabled()) {
        return;
    }

    perfetto::TrackEvent::Flush();
}

#ifdef __cplusplus
}
#endif

#else // ETCH_ENABLE_PERFETTO not defined

// Stub implementations when Perfetto is not enabled

#ifdef __cplusplus
extern "C" {
#endif

bool etch_perfetto_init(const char* process_name, const char* output_file) {
    return false;
}

void etch_perfetto_shutdown(void) {
    // No-op
}

bool etch_perfetto_is_enabled(void) {
    return false;
}

void etch_perfetto_begin_event(const char* category, const char* name, uint64_t id) {
    // No-op
}

void etch_perfetto_end_event(const char* category, const char* name, uint64_t id) {
    // No-op
}

void etch_perfetto_instant_event(const char* category, const char* name, const char* scope) {
    // No-op
}

void etch_perfetto_counter(const char* category, const char* name, int64_t value, const char* unit) {
    // No-op
}

void etch_perfetto_flush(void) {
    // No-op
}

#ifdef __cplusplus
}
#endif

#endif // ETCH_ENABLE_PERFETTO