/**
 * Test double. Lets a test hand the parser an exact payload - including the
 * awkward ones a real model will not produce on demand (conflicting dates,
 * missing evidence, malformed JSON).
 */
@IsTest
public with sharing class MockLLMService implements ILLMService {

    private final LLMResponse canned;

    public MockLLMService(String textToReturn) {
        this.canned = LLMResponse.ok(textToReturn, 200, 1);
    }

    public MockLLMService(LLMResponse response) {
        this.canned = response;
    }

    public static MockLLMService failing(String message) {
        return new MockLLMService(LLMResponse.fail(message, 500, 1));
    }

    public LLMResponse ask(String systemPrompt, String userPrompt) {
        return canned;
    }
}
