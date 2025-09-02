/**
 * @file etch_perfetto.h
 *
 * @brief C wrapper for Perfetto profiling integration
 *
 * This header provides a C interface for Perfetto tracing functionality
 * used by the Etch VM profiler.
 */

#ifndef ETCH_PERFETTO_H
#define ETCH_PERFETTO_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize Perfetto tracing system
 *
 * @param process_name Name of the process (e.g., "etch")
 * @param output_file Path to output trace file (NULL for default)
 * @return true on success, false on failure
 */
bool etch_perfetto_init(const char* process_name, const char* output_file);

/**
 * Shutdown Perfetto tracing system
 */
void etch_perfetto_shutdown(void);

/**
 * Check if Perfetto is initialized and ready
 *
 * @return true if tracing is active
 */
bool etch_perfetto_is_enabled(void);

/**
 * Begin a tracing event (function enter, instruction start, etc.)
 *
 * @param category Event category (e.g., "vm", "function")
 * @param name Event name (e.g., "execute_instruction", function name)
 * @param id Optional unique ID for the event (0 for none)
 */
void etch_perfetto_begin_event(const char* category, const char* name, uint64_t id);

/**
 * End a tracing event
 *
 * @param category Event category (must match begin_event)
 * @param name Event name (must match begin_event)
 * @param id Optional unique ID (must match begin_event)
 */
void etch_perfetto_end_event(const char* category, const char* name, uint64_t id);

/**
 * Record an instant event (single timestamp event)
 *
 * @param category Event category
 * @param name Event name
 * @param scope Event scope ("global", "process", "thread")
 */
void etch_perfetto_instant_event(const char* category, const char* name, const char* scope);

/**
 * Record a counter value
 *
 * @param category Counter category
 * @param name Counter name
 * @param value Counter value
 * @param unit Unit string (e.g., "count", "bytes")
 */
void etch_perfetto_counter(const char* category, const char* name, int64_t value, const char* unit);

/**
 * Flush pending trace data to disk
 */
void etch_perfetto_flush(void);

#ifdef __cplusplus
}
#endif

#endif /* ETCH_PERFETTO_H */