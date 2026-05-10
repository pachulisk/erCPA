/**
 * CLIPS Bridge Implementation
 * Wraps CLIPS 6.4 API for the Erlang port protocol
 * Uses Eval() for flexible fact queries and AssertString() for assertions
 */

#include "clips_bridge.h"
#include "clips.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

clips_env_t clips_bridge_init(void) {
    Environment *env = CreateEnvironment();
    return (clips_env_t)env;
}

void clips_bridge_destroy(clips_env_t env) {
    if (env) {
        DestroyEnvironment((Environment *)env);
    }
}

int clips_bridge_load(clips_env_t env, const char *filename) {
    LoadError result = Load((Environment *)env, filename);
    return (result == LE_NO_ERROR) ? 0 : -1;
}

long long clips_bridge_assert_json(clips_env_t env, const char *assert_str, size_t len) {
    (void)len;
    Fact *fact = AssertString((Environment *)env, assert_str);
    if (fact == NULL) return -1;
    return FactIndex(fact);
}

int clips_bridge_retract(clips_env_t env, long long fact_index) {
    Fact *fact;
    for (fact = GetNextFact((Environment *)env, NULL);
         fact != NULL;
         fact = GetNextFact((Environment *)env, fact)) {
        if (FactIndex(fact) == fact_index) {
            Retract(fact);
            return 0;
        }
    }
    return -1;
}

int clips_bridge_retract_all(clips_env_t env, const char *template_name) {
    (void)template_name;
    RetractAllFacts((Environment *)env);
    return 0;
}

int clips_bridge_run(clips_env_t env, int limit) {
    long long fired = Run((Environment *)env, (long long)limit);
    return (int)fired;
}

char* clips_bridge_query(clips_env_t env, const char *template_name,
                         const char *slot_name, const char *slot_value) {
    /*
     * Use (find-fact) via Eval to search for matching facts.
     * Build CLIPS expression: (find-fact ((?f template)) (eq ?f:slot value))
     * Then extract slot values from the result.
     */
    char expr[4096];
    CLIPSValue result;

    snprintf(expr, sizeof(expr),
        "(find-fact ((?f %s)) (eq (str-cat ?f:%s) \"%s\"))",
        template_name, slot_name, slot_value);

    EvalError err = Eval((Environment *)env, expr, &result);
    if (err != EE_NO_ERROR) {
        return strdup("null");
    }

    /* Result is a multifield — check if empty */
    if (result.header->type != MULTIFIELD_TYPE ||
        result.multifieldValue->length == 0) {
        return strdup("null");
    }

    /* Get first matching fact address */
    CLIPSValue factVal = result.multifieldValue->contents[0];
    if (factVal.header->type != FACT_ADDRESS_TYPE) {
        return strdup("null");
    }

    Fact *fact = factVal.factValue;

    /* Build JSON from fact using slot-value queries */
    char buf[65536];
    int pos = 0;
    pos += snprintf(buf + pos, sizeof(buf) - pos, "{");

    /* Get slot names via DeftemplateSlotNames */
    Deftemplate *tmpl = FactDeftemplate(fact);
    CLIPSValue slotNames;
    DeftemplateSlotNames(tmpl, &slotNames);

    if (slotNames.header->type == MULTIFIELD_TYPE) {
        size_t i;
        for (i = 0; i < slotNames.multifieldValue->length; i++) {
            if (i > 0) pos += snprintf(buf + pos, sizeof(buf) - pos, ",");

            const char *sname = slotNames.multifieldValue->contents[i].lexemeValue->contents;
            CLIPSValue sv;
            GetFactSlot(fact, sname, &sv);

            pos += snprintf(buf + pos, sizeof(buf) - pos, "\"%s\":", sname);

            if (sv.header->type == STRING_TYPE || sv.header->type == SYMBOL_TYPE) {
                pos += snprintf(buf + pos, sizeof(buf) - pos, "\"%s\"",
                                sv.lexemeValue->contents);
            } else if (sv.header->type == INTEGER_TYPE) {
                pos += snprintf(buf + pos, sizeof(buf) - pos, "%lld",
                                sv.integerValue->contents);
            } else if (sv.header->type == FLOAT_TYPE) {
                pos += snprintf(buf + pos, sizeof(buf) - pos, "%g",
                                sv.floatValue->contents);
            } else {
                pos += snprintf(buf + pos, sizeof(buf) - pos, "null");
            }
        }
    }

    pos += snprintf(buf + pos, sizeof(buf) - pos, "}");
    return strdup(buf);
}

int clips_bridge_reset(clips_env_t env) {
    Reset((Environment *)env);
    return 0;
}

void clips_bridge_free(char *str) {
    free(str);
}
