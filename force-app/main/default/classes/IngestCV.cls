/**
 * Agentforce action: take CV text, produce a Candidate Card.
 *
 * Bulk safe: one callout per CV, but only two DML statements regardless of
 * how many CVs arrive.
 */
public with sharing class IngestCV {

    public class Request {
        @InvocableVariable(required=true label='CV Text' description='The plain text of the CV')
        public String cvText;

        @InvocableVariable(label='File Name' description='Original file name, for provenance')
        public String fileName;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Candidate Id')
        public String candidateId;

        @InvocableVariable(label='Message' description='What was extracted, and what was flagged')
        public String message;
    }

    @InvocableMethod(
        label='Ingest CV'
        description='Extracts a structured Candidate Card from CV text, flagging missing, inferred and conflicting information.'
    )
    public static List<Result> run(List<Request> requests) {

        List<Result> results = new List<Result>();
        List<CVParser.ParseResult> parsed = new List<CVParser.ParseResult>();

        // Prompt is held in Apex (CVPrompts), not Custom Metadata - see class header on CVPrompts for why.
        String systemPrompt = CVPrompts.EXTRACTION;
        ILLMService llm = LLMServiceFactory.getService();

        // --- pass 1: reason over each CV -------------------------------
        for (Request req : requests) {
            Result r = new Result();

            if (String.isBlank(req.cvText)) {
                r.success = false;
                r.message = 'No CV text was provided.';
                results.add(r);
                parsed.add(null);
                continue;
            }

            LLMResponse llmResult = llm.ask(
                systemPrompt,
                'Extract facts from the CV below and return the JSON object described in your instructions. Output JSON only.\n\nCV TEXT:\n' + req.cvText
            );
            if (!llmResult.success) {
                AgentLogger.add('IngestCV', false, req.fileName, null,
                                llmResult.errorMessage, llmResult.durationMs, null);
                r.success = false;
                r.message = 'Could not read this CV: ' + llmResult.errorMessage;
                results.add(r);
                parsed.add(null);
                continue;
            }

            CVParser.ParseResult p = CVParser.parse(llmResult.text, req.cvText, req.fileName);

            if (!p.success) {
                AgentLogger.add('IngestCV', false, req.fileName, llmResult.text,
                                p.errorMessage, llmResult.durationMs, null);
                r.success = false;
                r.message = 'Could not structure this CV: ' + p.errorMessage;
                results.add(r);
                parsed.add(null);
                continue;
            }

            r.success = true;
            results.add(r);
            parsed.add(p);
        }

        // --- pass 2: one DML for candidates ----------------------------
        List<Candidate__c> candidates = new List<Candidate__c>();
        for (CVParser.ParseResult p : parsed) {
            if (p != null) {
                candidates.add(p.candidate);
            }
        }
        if (!candidates.isEmpty()) {
            insert candidates;
        }

        // --- pass 3: one DML for facts ---------------------------------
        List<Fact__c> allFacts = new List<Fact__c>();
        for (CVParser.ParseResult p : parsed) {
            if (p == null) {
                continue;
            }
            for (Fact__c f : p.facts) {
                f.Candidate__c = p.candidate.Id;
                allFacts.add(f);
            }
        }
        if (!allFacts.isEmpty()) {
            insert allFacts;
        }

        // --- pass 4: build messages and log ----------------------------
        for (Integer i = 0; i < parsed.size(); i++) {
            CVParser.ParseResult p = parsed[i];
            if (p == null) {
                continue;
            }
            results[i].candidateId = p.candidate.Id;
            results[i].message = summarise(p);
            AgentLogger.add('IngestCV', true, p.candidate.File_Name__c,
                            results[i].message, null, null, p.candidate.Id);
        }

        AgentLogger.flush();
        return results;
    }

    /** A message the recruiter can act on - counts of what needs checking. */
    private static String summarise(CVParser.ParseResult p) {
        Integer conflicting = 0;
        Integer missing = 0;
        Integer inferred = 0;
        for (Fact__c f : p.facts) {
            if (f.Certainty__c == 'Conflicting') { conflicting++; }
            else if (f.Certainty__c == 'Missing') { missing++; }
            else if (f.Certainty__c == 'Inferred') { inferred++; }
        }

        String msg = 'Created candidate card for ' + p.candidate.Name
                   + ' with ' + p.facts.size() + ' fact(s). '
                   + inferred + ' inferred, '
                   + conflicting + ' conflicting, '
                   + missing + ' missing.';

        if (!p.warnings.isEmpty()) {
            msg += ' Note: ' + String.join(p.warnings, ' ');
        }
        return msg;
    }
}
