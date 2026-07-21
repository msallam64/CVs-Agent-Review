/**
 * Result of a single LLM call. Carries success/failure explicitly so callers
 * never have to guess whether the text can be trusted.
 */
public with sharing class LLMResponse {
    public Boolean success { get; set; }
    public String text { get; set; }
    public String errorMessage { get; set; }
    public Integer statusCode { get; set; }
    public Long durationMs { get; set; }

    public static LLMResponse ok(String text, Integer status, Long ms) {
        LLMResponse r = new LLMResponse();
        r.success = true;
        r.text = text;
        r.statusCode = status;
        r.durationMs = ms;
        return r;
    }

    public static LLMResponse fail(String message, Integer status, Long ms) {
        LLMResponse r = new LLMResponse();
        r.success = false;
        r.errorMessage = message;
        r.statusCode = status;
        r.durationMs = ms;
        return r;
    }
}
