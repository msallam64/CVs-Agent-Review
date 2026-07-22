/**
 * The scoring policy - rubric criteria and certainty discounts - as data.
 *
 * Source of truth is Custom Metadata (Rubric_Criterion__mdt, Scoring_Config__mdt)
 * so a reviewer can read every number that produces a score. Apex holds a
 * fallback identical to the seeded records so scoring still works if the config
 * is absent, and a @TestVisible injection point so tests are independent of it.
 */
public with sharing class ScoringPolicy {

    public class Criterion {
        public String label;
        public Decimal weight;
        public String guidance;
        public Criterion(String label, Decimal weight, String guidance) {
            this.label = label;
            this.weight = weight;
            this.guidance = guidance;
        }
    }

    public class Config {
        public Decimal discountStated = 1.0;
        public Decimal discountInferred = 0.6;
        public Decimal discountConflicting = 0.4;
        public Decimal discountMissing = 0.0;
        public Decimal strongMatchThreshold = 60;

        public Decimal discountFor(String certainty) {
            if (certainty == 'Stated')      { return discountStated; }
            if (certainty == 'Inferred')    { return discountInferred; }
            if (certainty == 'Conflicting') { return discountConflicting; }
            return discountMissing;
        }
    }

    @TestVisible private static List<Criterion> injectedCriteria;
    @TestVisible private static Config injectedConfig;

    public static List<Criterion> criteria() {
        if (injectedCriteria != null) {
            return injectedCriteria;
        }
        List<Criterion> out = new List<Criterion>();
        for (Rubric_Criterion__mdt r : Rubric_Criterion__mdt.getAll().values()) {
            if (r.Active__c == true) {
                out.add(buildCriterion(r));
            }
        }
        return out.isEmpty() ? defaultCriteria() : out;
    }

    public static Config config() {
        if (injectedConfig != null) {
            return injectedConfig;
        }
        Scoring_Config__mdt c = Scoring_Config__mdt.getInstance('Default');
        return c == null ? new Config() : buildConfig(c);
    }

    @TestVisible
    private static Criterion buildCriterion(Rubric_Criterion__mdt r) {
        return new Criterion(r.MasterLabel, r.Weight__c, r.Guidance__c);
    }

    @TestVisible
    private static Config buildConfig(Scoring_Config__mdt c) {
        Config cfg = new Config();
        cfg.discountStated      = nvl(c.Discount_Stated__c, 1.0);
        cfg.discountInferred    = nvl(c.Discount_Inferred__c, 0.6);
        cfg.discountConflicting = nvl(c.Discount_Conflicting__c, 0.4);
        cfg.discountMissing     = nvl(c.Discount_Missing__c, 0.0);
        cfg.strongMatchThreshold = nvl(c.Strong_Match_Threshold__c, 60);
        return cfg;
    }

    // Same values seeded in Rubric_Criterion__mdt - keeps scoring working if config is absent.
    private static List<Criterion> defaultCriteria() {
        return new List<Criterion>{
            new Criterion('Technical Skills', 40, 'Depth and relevance of technical skills for the role.'),
            new Criterion('Relevant Experience', 30, 'Years and relevance of hands-on experience to the role.'),
            new Criterion('Education', 15, 'Relevant qualifications, degrees and certifications.'),
            new Criterion('Achievements', 15, 'Notable achievements, measurable impact and recognition.')
        };
    }

    private static Decimal nvl(Decimal v, Decimal fallback) {
        return v == null ? fallback : v;
    }
}
