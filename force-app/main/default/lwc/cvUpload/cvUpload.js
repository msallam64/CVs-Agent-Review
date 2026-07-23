import { LightningElement } from 'lwc';
import ingestCV from '@salesforce/apex/CVAgentController.ingestCV';

export default class CvUpload extends LightningElement {
    cvText = '';
    fileName = '';
    result;
    error;
    loading = false;

    handleText(event) {
        this.cvText = event.target.value;
    }

    // Extraction boundary: .txt is read client-side; PDF/DOC extraction is a
    // deliberate stub (documented) - paste the text for those formats.
    handleFile(event) {
        const file = event.target.files && event.target.files[0];
        if (!file) {
            return;
        }
        this.fileName = file.name;
        this.error = undefined;
        if (file.type === 'text/plain' || file.name.toLowerCase().endsWith('.txt')) {
            const reader = new FileReader();
            reader.onload = () => {
                this.cvText = reader.result;
            };
            reader.readAsText(file);
        } else {
            this.error =
                'PDF/DOC text extraction is stubbed in this prototype. Paste the CV text below instead.';
        }
    }

    get canIngest() {
        return this.cvText && !this.loading;
    }

    async ingest() {
        this.loading = true;
        this.error = undefined;
        this.result = undefined;
        try {
            const v = await ingestCV({
                cvText: this.cvText,
                fileName: this.fileName || 'pasted.txt'
            });
            this.result = v;
            if (!v.success) {
                this.error = v.message;
            }
        } catch (e) {
            this.error = e?.body?.message || 'Ingestion failed.';
        } finally {
            this.loading = false;
        }
    }
}
