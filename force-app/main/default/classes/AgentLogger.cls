/**
 * Audit trail for agent actions. Buffered so a bulk run writes one DML,
 * not one per record.
 */
public with sharing class AgentLogger {

    private static final Integer MAX_LEN = 30000;
    private static List<Agent_Log__c> buffer = new List<Agent_Log__c>();

    public static void add(String action, Boolean ok, String input, String output,
                           String error, Long ms, Id candidateId) {
        buffer.add(new Agent_Log__c(
            Action__c       = action,
            Status__c       = ok ? 'Success' : 'Failure',
            Input__c        = truncate(input),
            Output__c       = truncate(output),
            Error__c        = truncate(error),
            Duration_ms__c  = ms,
            Candidate__c    = candidateId
        ));
    }

    public static void flush() {
        if (buffer.isEmpty()) {
            return;
        }
        try {
            insert buffer;
        } catch (Exception e) {
            // Logging must never break the action it is observing
            System.debug(LoggingLevel.ERROR, 'Agent log insert failed: ' + e.getMessage());
        }
        buffer.clear();
    }

    private static String truncate(String s) {
        if (String.isBlank(s)) {
            return s;
        }
        return s.length() > MAX_LEN ? s.substring(0, MAX_LEN) : s;
    }
}
