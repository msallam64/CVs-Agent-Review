/**
 * Proves the one thing the mock-based tests can't: how ClaudeService reads a
 * real HTTP response. The headline case is a 200 that carries an error object
 * in its body - Anthropic does this for some failures, and trusting the status
 * code alone would treat it as success.
 */
@IsTest
private class ClaudeServiceTest {

    private class Mock implements HttpCalloutMock {
        private Integer status;
        private String body;
        private Boolean blowUp = false;
        Mock(Integer status, String body) { this.status = status; this.body = body; }
        Mock(Boolean blowUp) { this.blowUp = blowUp; }

        public HttpResponse respond(HttpRequest req) {
            if (blowUp) {
                throw new CalloutException('socket closed');
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setBody(body);
            return res;
        }
    }

    private static LLMResponse call(HttpCalloutMock mock) {
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        LLMResponse r = new ClaudeService().ask('system', 'user');
        Test.stopTest();
        return r;
    }

    @IsTest
    static void success_returns_text_with_the_prefill_brace() {
        // The assistant turn is prefilled with '{', so the model text is the
        // remainder; ClaudeService reassembles the whole object.
        LLMResponse r = call(new Mock(200,
            '{"content":[{"type":"text","text":"\\"name\\":\\"Omar\\"}"}]}'));

        System.assert(r.success, 'A clean 200 with content is a success');
        System.assert(r.text.startsWith('{'), 'Reassembled JSON begins with the prefill brace');
        System.assert(r.text.contains('Omar'), 'Model text is carried through');
    }

    @IsTest
    static void error_object_inside_a_200_is_treated_as_failure() {
        // THE POINT: 200 status, but the body is an error. Must not be trusted.
        LLMResponse r = call(new Mock(200,
            '{"type":"error","error":{"type":"overloaded_error","message":"boom"}}'));

        System.assert(!r.success, 'An error body must fail even on a 200');
        System.assert(r.errorMessage.contains('boom'), 'The API message is surfaced');
    }

    @IsTest
    static void non_200_status_fails() {
        LLMResponse r = call(new Mock(429, '{"note":"rate limited"}'));

        System.assert(!r.success);
        System.assert(r.errorMessage.contains('429'), 'The status is reported');
    }

    @IsTest
    static void empty_content_fails() {
        LLMResponse r = call(new Mock(200, '{"content":[]}'));

        System.assert(!r.success, 'No content means no answer');
    }

    @IsTest
    static void unparseable_body_fails() {
        LLMResponse r = call(new Mock(200, 'this is not json'));

        System.assert(!r.success, 'A body that will not parse cannot be trusted');
    }

    @IsTest
    static void callout_exception_is_caught() {
        LLMResponse r = call(new Mock(true));

        System.assert(!r.success, 'A transport failure must never bubble into the agent');
        System.assert(r.errorMessage.contains('Callout failed'), 'The failure is described');
    }
}
