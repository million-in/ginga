import type {
  PreviewBridgeOutcome,
  PreviewEnginePayload,
  PreviewEngineResponse
} from './shared';

function mustGetElement<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) {
    throw new Error(`Missing required element #${id}`);
  }

  return element as T;
}

const imagePathInput = mustGetElement<HTMLInputElement>('imagePath');
const browseButton = mustGetElement<HTMLButtonElement>('browseButton');
const previewButton = mustGetElement<HTMLButtonElement>('previewButton');
const statusNode = mustGetElement<HTMLElement>('status');
const resultNode = mustGetElement<HTMLElement>('result');
const previewImageNode = mustGetElement<HTMLImageElement>('previewImage');
const previewPlaceholderNode = mustGetElement<HTMLElement>('previewPlaceholder');

function setStatus(message: string): void {
  statusNode.textContent = message;
}

function setResult(value: unknown): void {
  resultNode.textContent = JSON.stringify(value, null, 2);
}

function clearPreview(message: string): void {
  previewImageNode.hidden = true;
  previewImageNode.removeAttribute('src');
  previewPlaceholderNode.hidden = false;
  previewPlaceholderNode.textContent = message;
}

function setPreview(response: PreviewEngineResponse): void {
  const base64 = response.payload?.previewPngBase64;
  if (!base64) {
    clearPreview('The engine returned no preview PNG payload.');
    return;
  }

  previewImageNode.src = `data:image/png;base64,${base64}`;
  previewImageNode.hidden = false;
  previewPlaceholderNode.hidden = true;
}

function summarizePayload(payload: PreviewEnginePayload): Record<string, unknown> {
  return {
    ok: payload.ok,
    format: payload.format,
    sourceWidth: payload.sourceWidth,
    sourceHeight: payload.sourceHeight,
    previewWidth: payload.previewWidth,
    previewHeight: payload.previewHeight,
    previewPngBase64Bytes: payload.previewPngBase64 ? payload.previewPngBase64.length : 0
  };
}

function summarizeResponse(response: PreviewEngineResponse): Record<string, unknown> {
  return {
    ok: true,
    binaryPath: response.binaryPath,
    command: response.command,
    request: response.request,
    stderr: response.stderr,
    payload: summarizePayload(response.payload ?? {})
  };
}

async function chooseImage(): Promise<void> {
  setStatus('Opening file dialog...');
  const response = await window.ginga.openImageDialog();
  if (response.canceled) {
    setStatus('Image selection canceled.');
    return;
  }

  imagePathInput.value = response.filePath;
  setStatus('Image path selected.');
}

async function previewImage(): Promise<void> {
  const imagePath = imagePathInput.value.trim();
  if (!imagePath) {
    setStatus('Enter an image path before previewing.');
    setResult({ ok: false, error: 'Missing image path' });
    return;
  }

  previewButton.disabled = true;
  setStatus('Running ginga preview...');

  try {
    const outcome = (await window.ginga.previewImage(imagePath)) as PreviewBridgeOutcome;
    if (!outcome.ok) {
      clearPreview('Preview failed before an image could be rendered.');
      setResult({
        ok: false,
        error: outcome.error ?? { message: 'Unknown preview failure' }
      });
      setStatus('Preview failed.');
      return;
    }

    setPreview(outcome.response);
    setResult(summarizeResponse(outcome.response));
    setStatus('Preview completed.');
  } catch (error) {
    clearPreview('Preview failed before an image could be rendered.');
    setResult({
      ok: false,
      error: error instanceof Error ? error.message : String(error),
      stdout: error && typeof error === 'object' ? (error as { stdout?: string }).stdout ?? '' : '',
      stderr: error && typeof error === 'object' ? (error as { stderr?: string }).stderr ?? '' : ''
    });
    setStatus('Preview failed.');
  } finally {
    previewButton.disabled = false;
  }
}

browseButton.addEventListener('click', () => {
  void chooseImage();
});

previewButton.addEventListener('click', () => {
  void previewImage();
});

imagePathInput.addEventListener('keydown', (event: KeyboardEvent) => {
  if (event.key === 'Enter') {
    event.preventDefault();
    void previewImage();
  }
});

clearPreview('Run a preview to render the PNG output here.');
setResult({ ok: false, note: 'No preview has been run yet.' });
