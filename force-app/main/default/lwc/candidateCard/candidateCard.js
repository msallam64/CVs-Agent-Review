import { LightningElement, api, wire } from 'lwc';
import getCandidateCard from '@salesforce/apex/CVAgentController.getCandidateCard';

// Certainty drives the visual language: strongest evidence green, absence grey.
const CERTAINTY_META = {
    Stated: { theme: 'cert cert_stated', icon: 'utility:success' },
    Inferred: { theme: 'cert cert_inferred', icon: 'utility:info' },
    Conflicting: { theme: 'cert cert_conflicting', icon: 'utility:warning' },
    Missing: { theme: 'cert cert_missing', icon: 'utility:dash' }
};

export default class CandidateCard extends LightningElement {
    @api recordId; // auto-populated on a Candidate record page
    @api candidateId; // set explicitly when embedded elsewhere

    card;
    error;

    get resolvedId() {
        return this.candidateId || this.recordId;
    }

    @wire(getCandidateCard, { candidateId: '$resolvedId' })
    wired({ data, error }) {
        if (data) {
            this.card = {
                candidate: data.candidate,
                groups: data.groups.map((g) => ({
                    certainty: g.certainty,
                    facts: g.facts,
                    count: g.facts.length,
                    ...CERTAINTY_META[g.certainty]
                }))
            };
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Could not load this candidate.';
        }
    }

    get hasCard() {
        return this.card && this.card.candidate;
    }
}
