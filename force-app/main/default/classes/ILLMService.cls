/**
 * The only contract the rest of the app depends on. Swapping Claude for
 * another provider, or for a mock in tests, means swapping the implementation.
 */
public interface ILLMService {
    LLMResponse ask(String systemPrompt, String userPrompt);
}
