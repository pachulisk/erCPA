/**
 * CLIPS Port Program - Erlang Port stdin/stdout JSON Protocol
 *
 * Protocol: Line-delimited JSON on stdin/stdout
 *
 * Request format:
 *   {"op":"assert","fact":["template_name",{...slots...}]}
 *   {"op":"retract","fact-id":42}
 *   {"op":"retract-all","template":"credential"}
 *   {"op":"run","limit":-1}
 *   {"op":"query","template":"selection-result","slot":"request-id","value":"r1"}
 *   {"op":"reset"}
 *   {"op":"load","file":"path/to/rules.clp"}
 *
 * Response format:
 *   {"ok":true,"fact-id":42}
 *   {"ok":true,"fired":5}
 *   {"ok":true,"result":{...}}
 *   {"ok":true,"results":[...]}
 *   {"error":"message"}
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "clips_bridge.h"

#define MAX_LINE 1048576  /* 1MB max line length */

static char line_buffer[MAX_LINE];
static clips_env_t g_env = NULL;

static void send_ok(const char *extra) {
    if (extra && strlen(extra) > 0) {
        printf("{\"ok\":true,%s}\n", extra);
    } else {
        printf("{\"ok\":true}\n");
    }
    fflush(stdout);
}

static void send_error(const char *msg) {
    printf("{\"error\":\"%s\"}\n", msg);
    fflush(stdout);
}

static void send_result(const char *json) {
    printf("{\"ok\":true,\"result\":%s}\n", json);
    fflush(stdout);
}

static void handle_line(const char *line, size_t len) {
    /* TODO: Parse JSON using a lightweight JSON parser (e.g., cJSON)
     * For now, this is a stub that acknowledges all commands */
    (void)len;

    if (strstr(line, "\"op\":\"reset\"")) {
        clips_bridge_reset(g_env);
        send_ok("");
    } else if (strstr(line, "\"op\":\"run\"")) {
        int fired = clips_bridge_run(g_env, -1);
        char buf[64];
        snprintf(buf, sizeof(buf), "\"fired\":%d", fired);
        send_ok(buf);
    } else if (strstr(line, "\"op\":\"assert\"")) {
        long long fid = clips_bridge_assert_json(g_env, line, strlen(line));
        char buf[64];
        snprintf(buf, sizeof(buf), "\"fact-id\":%lld", fid);
        send_ok(buf);
    } else if (strstr(line, "\"op\":\"retract\"")) {
        /* TODO: extract fact-id from JSON */
        clips_bridge_retract(g_env, 0);
        send_ok("");
    } else if (strstr(line, "\"op\":\"retract-all\"")) {
        /* TODO: extract template name from JSON */
        clips_bridge_retract_all(g_env, "");
        send_ok("");
    } else if (strstr(line, "\"op\":\"query\"")) {
        char *result = clips_bridge_query(g_env, "", "", "");
        send_result(result);
        clips_bridge_free(result);
    } else if (strstr(line, "\"op\":\"load\"")) {
        /* TODO: extract file path from JSON */
        clips_bridge_load(g_env, "");
        send_ok("");
    } else {
        send_error("unknown op");
    }
}

int main(void) {
    /* Initialize CLIPS environment */
    g_env = clips_bridge_init();
    if (!g_env) {
        fprintf(stderr, "Failed to initialize CLIPS environment\n");
        return 1;
    }

    /* Main read loop - read lines from stdin */
    while (fgets(line_buffer, MAX_LINE, stdin) != NULL) {
        size_t len = strlen(line_buffer);
        /* Strip trailing newline */
        if (len > 0 && line_buffer[len - 1] == '\n') {
            line_buffer[--len] = '\0';
        }
        if (len == 0) continue;

        handle_line(line_buffer, len);
    }

    /* Cleanup */
    clips_bridge_destroy(g_env);
    return 0;
}
