/**
 * Single place that decides which implementation the app uses. Tests inject a
 * mock here; production always gets the real Claude service.
 */
public with sharing class LLMServiceFactory {

    @TestVisible
    private static ILLMService injected;

    public static ILLMService getService() {
        if (injected != null) {
            return injected;
        }
        return new ClaudeService();
    }

    @TestVisible
    private static void setMock(ILLMService mock) {
        injected = mock;
    }
}
