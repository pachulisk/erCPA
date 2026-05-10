/**
 * CLIPS Bridge - C wrapper around CLIPS API
 * Provides simplified interface for the Erlang port protocol
 */

#ifndef CLIPS_BRIDGE_H
#define CLIPS_BRIDGE_H

#include <stddef.h>

/* Opaque handle to CLIPS environment */
typedef void* clips_env_t;

/* Initialize a new CLIPS environment */
clips_env_t clips_bridge_init(void);

/* Destroy CLIPS environment */
void clips_bridge_destroy(clips_env_t env);

/* Load a .clp file into the environment */
int clips_bridge_load(clips_env_t env, const char *filename);

/* Assert a fact from JSON representation */
long long clips_bridge_assert_json(clips_env_t env, const char *json, size_t json_len);

/* Retract a fact by index */
int clips_bridge_retract(clips_env_t env, long long fact_index);

/* Retract all facts matching a template name */
int clips_bridge_retract_all(clips_env_t env, const char *template_name);

/* Run the inference engine (returns number of rules fired) */
int clips_bridge_run(clips_env_t env, int limit);

/* Query facts matching template + slot value, returns JSON */
char* clips_bridge_query(clips_env_t env, const char *template_name,
                         const char *slot_name, const char *slot_value);

/* Reset the environment (clear all facts, reload rules) */
int clips_bridge_reset(clips_env_t env);

/* Free a string returned by query functions */
void clips_bridge_free(char *str);

#endif /* CLIPS_BRIDGE_H */
