/**
 * The single door to Claude. All model config comes from Custom Metadata so
 * the model or token budget can change without a deployment.
 */
public with sharing class ClaudeService implements ILLMService {

    private final LLM_Config__mdt cfg;

    public ClaudeService() {
        this.cfg = LLM_Config__mdt.getInstance('Default');
    }

    public LLMResponse ask(String systemPrompt, String userPrompt) {
        Long started = System.currentTimeMillis();
        try {
            HttpResponse res = new Http().send(buildRequest(systemPrompt, userPrompt));
            return interpret(res, System.currentTimeMillis() - started);
        } catch (Exception e) {
            // Timeouts, DNS, unauthorized endpoint - never let this bubble into the agent
            return LLMResponse.fail('Callout failed: ' + e.getMessage(), 0,
                                    System.currentTimeMillis() - started);
        }
    }

    private HttpRequest buildRequest(String systemPrompt, String userPrompt) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + cfg.Named_Credential__c + '/v1/messages');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);

        Map<String, Object> payload = new Map<String, Object>{
            'model'      => cfg.Model__c,
            'max_tokens' => Integer.valueOf(cfg.Max_Tokens__c),
            'system'     => systemPrompt,
            'messages'   => new List<Object>{
                new Map<String, Object>{ 'role' => 'user',      'content' => userPrompt },
                new Map<String, Object>{ 'role' => 'assistant', 'content' => '{' }
            }
        };
        req.setBody(JSON.serialize(payload));
        return req;
    }

    /**
     * Anthropic can return an error object inside a 200-shaped body (billing,
     * rate limits). Checking the status code alone is not enough.
     */
    private LLMResponse interpret(HttpResponse res, Long ms) {
        Integer status = res.getStatusCode();
        String body = res.getBody();

        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (Exception e) {
            return LLMResponse.fail('Unparseable response body', status, ms);
        }

        if (parsed.containsKey('error')) {
            Object err = parsed.get('error');
            String msg = (err instanceof Map<String, Object>)
                ? String.valueOf(((Map<String, Object>) err).get('message'))
                : String.valueOf(err);
            return LLMResponse.fail('API error: ' + msg, status, ms);
        }

        if (status != 200) {
            return LLMResponse.fail('HTTP ' + status, status, ms);
        }

        List<Object> content = (List<Object>) parsed.get('content');
        if (content == null || content.isEmpty()) {
            return LLMResponse.fail('Empty content in response', status, ms);
        }

        String text = String.valueOf(((Map<String, Object>) content[0]).get('text'));
        return LLMResponse.ok('{' + text, status, ms);
    }
}
