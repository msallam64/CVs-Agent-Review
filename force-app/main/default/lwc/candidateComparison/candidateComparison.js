import { LightningElement, wire } from 'lwc';
import listCandidates from '@salesforce/apex/CVAgentController.listCandidates';
import compareCandidates from '@salesforce/apex/CVAgentController.compareCandidates';

export default class CandidateComparison extends LightningElement {
    role = '';
    candidateOptions = [];
    selectedIds = [];
    result;
    scorecards = [];
    loading = false;
    error;

    @wire(listCandidates)
    wiredCandidates({ data, error }) {
        if (data) {
            this.candidateOptions = data.map((c) => ({ label: c.Name, value: c.Id }));
        } else if (error) {
            this.error = 'Could not load candidates.';
        }
    }

    handleRole(event) {
        this.role = event.target.value;
    }

    handleSelect(event) {
        this.selectedIds = event.detail.value;
    }

    get canCompare() {
        return this.role && this.selectedIds.length > 0 && !this.loading;
    }

    get recommendationClass() {
        return this.result && this.result.strongMatch
            ? 'slds-box slds-theme_success slds-m-bottom_small'
            : 'slds-box slds-theme_warning slds-m-bottom_small';
    }

    async compare() {
        this.loading = true;
        this.error = undefined;
        this.result = undefined;
        this.scorecards = [];
        try {
            const v = await compareCandidates({ role: this.role, candidateIds: this.selectedIds });
            this.result = v;
            if (v.scorecardsJson) {
                this.scorecards = JSON.parse(v.scorecardsJson).map((s, i) => ({
                    ...s,
                    rank: i + 1,
                    coverageStyle: `width:${s.coverage}%`,
                    hasStrengths: s.strengths && s.strengths.length > 0,
                    hasConcerns: s.concerns && s.concerns.length > 0,
                    hasGaps: s.gaps && s.gaps.length > 0,
                    strengthsText: (s.strengths || []).join(', '),
                    concernsText: (s.concerns || []).join(', '),
                    gapsText: (s.gaps || []).join(', ')
                }));
            }
            if (!v.success) {
                this.error = v.summary;
            }
        } catch (e) {
            this.error = e?.body?.message || 'Comparison failed.';
        } finally {
            this.loading = false;
        }
    }
}
