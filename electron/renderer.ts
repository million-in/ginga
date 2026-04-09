import type {
  ConvertBridgeOutcome,
  ConvertEngineResponse,
  ConversionDetails,
  InspectBridgeOutcome,
  InspectEnginePayload,
  OutputFormat,
  PreviewBridgeOutcome,
  PreviewEnginePayload,
  PreviewEngineResponse
} from './shared';

type SupportedInputFormat = OutputFormat;

type GalleryState = {
  directoryPath: string;
  filePaths: string[];
  currentIndex: number;
};

type BatchItemSummary = {
  inputPath: string;
  outputPath: string;
  ok: boolean;
  compressionRatio: number | null;
  error?: string;
};

function mustGetElement<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) {
    throw new Error(`Missing required element #${id}`);
  }
  return element as T;
}

function withAsyncStatus(task: () => Promise<void>): () => void {
  return () => {
    task().catch((error: unknown) => {
      clearPreview('The desktop shell hit an unexpected error.');
      setStatus(`Unexpected error: ${error instanceof Error ? error.message : String(error)}`);
      setResult({
        ok: false,
        error: error instanceof Error ? error.message : String(error)
      });
    });
  };
}

const imagePathInput = mustGetElement<HTMLInputElement>('imagePath');
const outputPathInput = mustGetElement<HTMLInputElement>('outputPath');
const outputFormatSelect = mustGetElement<HTMLSelectElement>('outputFormat');
const qualityInput = mustGetElement<HTMLInputElement>('qualityInput');
const browseButton = mustGetElement<HTMLButtonElement>('browseButton');
const browseFolderButton = mustGetElement<HTMLButtonElement>('browseFolderButton');
const inspectButton = mustGetElement<HTMLButtonElement>('inspectButton');
const browseOutputButton = mustGetElement<HTMLButtonElement>('browseOutputButton');
const browseBatchButton = mustGetElement<HTMLButtonElement>('browseBatchButton');
const previousImageButton = mustGetElement<HTMLButtonElement>('previousImageButton');
const nextImageButton = mustGetElement<HTMLButtonElement>('nextImageButton');
const convertButton = mustGetElement<HTMLButtonElement>('convertButton');
const batchConvertButton = mustGetElement<HTMLButtonElement>('batchConvertButton');
const statusNode = mustGetElement<HTMLElement>('status');
const gallerySummaryNode = mustGetElement<HTMLElement>('gallerySummary');
const batchSummaryNode = mustGetElement<HTMLElement>('batchSummary');
const resultNode = mustGetElement<HTMLElement>('result');
const detailsNode = mustGetElement<HTMLElement>('details');
const previewFrameNode = mustGetElement<HTMLElement>('previewFrame');
const previewImageNode = mustGetElement<HTMLImageElement>('previewImage');
const previewPlaceholderNode = mustGetElement<HTMLElement>('previewPlaceholder');

let galleryState: GalleryState = {
  directoryPath: '',
  filePaths: [],
  currentIndex: -1
};
let batchSelection: string[] = [];
let swipeStartX: number | null = null;
let renderGeneration = 0;
let pendingRenderTimer: number | null = null;

function currentOutputFormat(): OutputFormat {
  return outputFormatSelect.value as OutputFormat;
}

function outputExtension(format: OutputFormat): string {
  return format === 'png' ? '.png' : format === 'spd' ? '.spd' : format === 'jpeg' ? '.jpeg' : '.jpg';
}

function setStatus(message: string): void {
  statusNode.textContent = message;
}

function setResult(value: unknown): void {
  resultNode.textContent = JSON.stringify(value, null, 2);
}

function replaceDetails(entries: Array<[label: string, value: string]>): void {
  detailsNode.replaceChildren();

  for (const [label, value] of entries) {
    const term = document.createElement('dt');
    term.textContent = label;
    const description = document.createElement('dd');
    description.textContent = value;
    detailsNode.append(term, description);
  }
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

function summarizeResponse(
  response: PreviewEngineResponse,
  inspectPayload?: InspectEnginePayload | null
): Record<string, unknown> {
  return {
    ok: true,
    binaryPath: response.binaryPath,
    command: response.command,
    request: response.request,
    stderr: response.stderr,
    payload: summarizePayload(response.payload ?? {}),
    inspect: inspectPayload ?? null
  };
}

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) {
    return 'unknown';
  }

  if (bytes < 1024) {
    return `${bytes} B`;
  }

  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KiB`;
  }

  return `${(bytes / (1024 * 1024)).toFixed(2)} MiB`;
}

function formatCompressionRatio(value: number | null): string {
  if (!value || !Number.isFinite(value)) {
    return 'n/a';
  }

  return `${value.toFixed(2)}x`;
}

function fileNameFromPath(filePath: string): string {
  const normalized = filePath.replace(/\\/g, '/');
  const index = normalized.lastIndexOf('/');
  return index === -1 ? normalized : normalized.slice(index + 1);
}

function stripFileExtension(filePath: string): string {
  const name = fileNameFromPath(filePath);
  const dotIndex = name.lastIndexOf('.');
  return dotIndex <= 0 ? name : name.slice(0, dotIndex);
}

function directorySeparator(directoryPath: string): string {
  return directoryPath.includes('\\') && !directoryPath.includes('/') ? '\\' : '/';
}

function joinPath(directoryPath: string, name: string): string {
  const separator = directorySeparator(directoryPath);
  if (!directoryPath) {
    return name;
  }
  return directoryPath.endsWith('/') || directoryPath.endsWith('\\')
    ? `${directoryPath}${name}`
    : `${directoryPath}${separator}${name}`;
}

function normalizeOutputPath(inputPath: string, format: OutputFormat): string {
  if (!inputPath) {
    return '';
  }

  const slashIndex = Math.max(inputPath.lastIndexOf('/'), inputPath.lastIndexOf('\\'));
  const directoryPath = slashIndex === -1 ? '' : inputPath.slice(0, slashIndex);
  return joinPath(directoryPath, `${stripFileExtension(inputPath)}-converted${outputExtension(format)}`);
}

function buildBatchOutputPath(inputPath: string, outputDirectory: string, format: OutputFormat): string {
  return joinPath(outputDirectory, `${stripFileExtension(inputPath)}${outputExtension(format)}`);
}

function inferInputFormat(filePath: string): SupportedInputFormat | null {
  const lower = filePath.toLowerCase();
  if (lower.endsWith('.png')) return 'png';
  if (lower.endsWith('.jpg')) return 'jpg';
  if (lower.endsWith('.jpeg')) return 'jpeg';
  if (lower.endsWith('.spd')) return 'spd';
  return null;
}

function setCurrentImagePath(filePath: string): void {
  imagePathInput.value = filePath;
  outputPathInput.value = normalizeOutputPath(filePath, currentOutputFormat());
}

function clearGallery(): void {
  galleryState = {
    directoryPath: '',
    filePaths: [],
    currentIndex: -1
  };
  updateGallerySummary();
}

function syncOutputControls(): void {
  const outputFormat = currentOutputFormat();
  const usesQuality = outputFormat === 'jpg' || outputFormat === 'jpeg';
  qualityInput.disabled = !usesQuality;
  qualityInput.setAttribute('aria-disabled', usesQuality ? 'false' : 'true');

  if (imagePathInput.value.trim()) {
    outputPathInput.value = normalizeOutputPath(imagePathInput.value.trim(), outputFormat);
  }
}

function parseQuality(): number {
  const parsed = Number.parseInt(qualityInput.value.trim(), 10);
  if (!Number.isFinite(parsed) || parsed < 1 || parsed > 100) {
    throw new Error('JPEG quality must be between 1 and 100');
  }

  return parsed;
}

function updateGallerySummary(): void {
  if (galleryState.filePaths.length === 0) {
    gallerySummaryNode.textContent = 'No folder loaded.';
    previousImageButton.disabled = true;
    nextImageButton.disabled = true;
    return;
  }

  const currentPath = galleryState.filePaths[galleryState.currentIndex] ?? '';
  gallerySummaryNode.textContent = `${galleryState.currentIndex + 1} / ${galleryState.filePaths.length} · ${fileNameFromPath(currentPath)} · ${galleryState.directoryPath}`;
  previousImageButton.disabled = galleryState.currentIndex <= 0;
  nextImageButton.disabled = galleryState.currentIndex >= galleryState.filePaths.length - 1;
}

function updateBatchSummary(): void {
  if (batchSelection.length === 0) {
    batchSummaryNode.textContent = 'No batch selection.';
    return;
  }

  const inputFormat = inferInputFormat(batchSelection[0]) ?? 'unknown';
  batchSummaryNode.textContent = `${batchSelection.length} files selected · input format ${inputFormat}`;
}

function renderPreviewDetails(
  imagePath: string,
  response: PreviewEngineResponse,
  inspectPayload: InspectEnginePayload | null
): void {
  const payload = response.payload;
  const entries: Array<[label: string, value: string]> = [
    ['Mode', 'Preview'],
    ['File', fileNameFromPath(imagePath)],
    ['Source format', payload.format ?? 'unknown'],
    ['Source size', `${payload.sourceWidth ?? 0} × ${payload.sourceHeight ?? 0}`],
    ['Preview size', `${payload.previewWidth ?? 0} × ${payload.previewHeight ?? 0}`],
    ['Spectral mode', response.request.spectralMode ?? 'none'],
    ['Preview encoding', 'png'],
    ['Pipeline', 'Zig render engine']
  ];

  if (galleryState.filePaths.length > 0 && galleryState.currentIndex >= 0) {
    entries.push(['Folder item', `${galleryState.currentIndex + 1} / ${galleryState.filePaths.length}`]);
  }

  if (inspectPayload?.format === 'spd') {
    entries.push(['Samples per pixel', String(inspectPayload.sampleCount)]);
    entries.push(['Wavelength start', `${inspectPayload.lambdaMinNm.toFixed(3)} nm`]);
    entries.push(['Wavelength step', `${inspectPayload.lambdaStepNm.toFixed(3)} nm`]);
  }

  if (inspectPayload?.format === 'jpeg') {
    entries.push(['JPEG components', String(inspectPayload.components)]);
    entries.push(['Baseline', inspectPayload.baseline ? 'true' : 'false']);
  }

  replaceDetails(entries);
}

function renderInspectDetails(imagePath: string, payload: InspectEnginePayload): void {
  const entries: Array<[label: string, value: string]> = [
    ['Mode', 'Inspect'],
    ['File', fileNameFromPath(imagePath)],
    ['Format', payload.format],
    ['Dimensions', `${payload.width} × ${payload.height}`]
  ];

  if (payload.format === 'jpeg') {
    entries.push(['Precision', String(payload.precision)]);
    entries.push(['Components', String(payload.components)]);
    entries.push(['Baseline', payload.baseline ? 'true' : 'false']);
    entries.push(['Progressive', payload.progressive ? 'true' : 'false']);
  }

  if (payload.format === 'spd') {
    entries.push(['Samples per pixel', String(payload.sampleCount)]);
    entries.push(['Wavelength start', `${payload.lambdaMinNm.toFixed(3)} nm`]);
    entries.push(['Wavelength step', `${payload.lambdaStepNm.toFixed(3)} nm`]);
  }

  replaceDetails(entries);
}

function renderConversionDetails(details: ConversionDetails): void {
  replaceDetails([
    ['Mode', 'Convert'],
    ['Source format', details.sourceFormat],
    ['Output format', details.outputFormat],
    ['Encoding', details.outputEncoding],
    ['Source size', `${details.sourceWidth} × ${details.sourceHeight}`],
    ['Output size', `${details.outputWidth} × ${details.outputHeight}`],
    ['Source bytes', formatBytes(details.sourceBytes)],
    ['Output bytes', formatBytes(details.outputBytes)],
    ['Compression ratio', formatCompressionRatio(details.compressionRatio)],
    ['Quality', details.quality === null ? 'n/a' : String(details.quality)]
  ]);
}

function summarizeConversionResponse(response: ConvertEngineResponse): Record<string, unknown> {
  return {
    ok: true,
    binaryPath: response.binaryPath,
    command: response.command,
    request: response.request,
    details: response.details,
    source: response.source.payload,
    output: response.output.payload,
    stderr: response.stderr
  };
}

async function inspectPayload(imagePath: string): Promise<InspectEnginePayload | null> {
  const outcome = (await window.ginga.inspectImage(imagePath)) as InspectBridgeOutcome;
  if (!outcome.ok) {
    return null;
  }
  return outcome.response.payload;
}

async function renderPath(imagePath: string): Promise<void> {
  const trimmedPath = imagePath.trim();
  if (!trimmedPath) {
    clearPreview('Open an image or folder to render immediately.');
    replaceDetails([['Mode', 'Preview'], ['Status', 'Missing image path']]);
    setResult({ ok: false, error: 'Missing image path' });
    setStatus('Missing image path.');
    return;
  }

  const generation = ++renderGeneration;
  setStatus('Rendering preview...');
  const [previewOutcome, inspect] = await Promise.all([
    window.ginga.previewImage(trimmedPath) as Promise<PreviewBridgeOutcome>,
    inspectPayload(trimmedPath)
  ]);

  if (generation !== renderGeneration) return;

  if (!previewOutcome.ok) {
    clearPreview('Preview failed before an image could be rendered.');
    replaceDetails([
      ['Mode', 'Preview'],
      ['Status', 'Failed'],
      ['Error', previewOutcome.error?.message ?? 'Unknown preview failure']
    ]);
    setResult({
      ok: false,
      error: previewOutcome.error ?? { message: 'Unknown preview failure' },
      inspect
    });
    setStatus('Preview failed.');
    return;
  }

  setPreview(previewOutcome.response);
  renderPreviewDetails(trimmedPath, previewOutcome.response, inspect);
  const summary = summarizeResponse(previewOutcome.response, inspect);
  if (previewOutcome.response.payload) {
    delete (previewOutcome.response.payload as Record<string, unknown>).previewPngBase64;
  }
  setResult(summary);
  setStatus('Preview completed.');
}

async function inspectCurrentImage(): Promise<void> {
  const imagePath = imagePathInput.value.trim();
  if (!imagePath) {
    setStatus('Enter an image path before inspecting.');
    replaceDetails([['Mode', 'Inspect'], ['Status', 'Missing image path']]);
    setResult({ ok: false, error: 'Missing image path' });
    return;
  }

  inspectButton.disabled = true;
  try {
    setStatus('Inspecting image...');
    const outcome = (await window.ginga.inspectImage(imagePath)) as InspectBridgeOutcome;
    if (!outcome.ok) {
      replaceDetails([
        ['Mode', 'Inspect'],
        ['Status', 'Failed'],
        ['Error', outcome.error?.message ?? 'Unknown inspect failure']
      ]);
      setResult({
        ok: false,
        error: outcome.error ?? { message: 'Unknown inspect failure' }
      });
      setStatus('Inspect failed.');
      return;
    }

    renderInspectDetails(imagePath, outcome.response.payload);
    setResult({
      ok: true,
      binaryPath: outcome.response.binaryPath,
      command: outcome.response.command,
      imagePath: outcome.response.imagePath,
      payload: outcome.response.payload,
      stderr: outcome.response.stderr
    });
    setStatus('Inspect completed.');
  } finally {
    inspectButton.disabled = false;
  }
}

async function chooseImage(): Promise<void> {
  setStatus('Opening image dialog...');
  const response = await window.ginga.openImageDialog();
  if (response.canceled) {
    setStatus('Image selection canceled.');
    return;
  }

  clearGallery();
  setCurrentImagePath(response.filePath);
  await renderPath(response.filePath);
}

async function chooseFolder(): Promise<void> {
  setStatus('Opening image folder dialog...');
  const response = await window.ginga.openImageFolderDialog();
  if (response.canceled) {
    setStatus('Folder selection canceled.');
    return;
  }

  if (response.filePaths.length === 0) {
    galleryState = { directoryPath: response.directoryPath, filePaths: [], currentIndex: -1 };
    updateGallerySummary();
    clearPreview('No supported images were found in the selected folder.');
    replaceDetails([['Mode', 'Preview'], ['Status', 'No supported images']]);
    setResult({ ok: false, error: 'No supported images in folder' });
    setStatus('Folder loaded with no supported images.');
    return;
  }

  galleryState = {
    directoryPath: response.directoryPath,
    filePaths: response.filePaths,
    currentIndex: 0
  };
  updateGallerySummary();
  setCurrentImagePath(galleryState.filePaths[0]);
  await renderPath(galleryState.filePaths[0]);
}

async function navigateGallery(delta: number): Promise<void> {
  if (galleryState.filePaths.length === 0) {
    setStatus('Load a folder before navigating.');
    return;
  }

  const nextIndex = Math.max(0, Math.min(galleryState.filePaths.length - 1, galleryState.currentIndex + delta));
  if (nextIndex === galleryState.currentIndex) {
    return;
  }

  galleryState.currentIndex = nextIndex;
  updateGallerySummary();
  setCurrentImagePath(galleryState.filePaths[nextIndex]);

  if (pendingRenderTimer !== null) {
    clearTimeout(pendingRenderTimer);
  }
  const targetPath = galleryState.filePaths[nextIndex];
  pendingRenderTimer = window.setTimeout(() => {
    pendingRenderTimer = null;
    renderPath(targetPath).catch((error: unknown) => {
      clearPreview('The desktop shell hit an unexpected error.');
      setStatus(`Unexpected error: ${error instanceof Error ? error.message : String(error)}`);
    });
  }, 120);
}

async function handleManualImagePathCommit(): Promise<void> {
  const imagePath = imagePathInput.value.trim();
  if (!imagePath) {
    return;
  }

  clearGallery();
  setCurrentImagePath(imagePath);
  await renderPath(imagePath);
}

async function chooseOutput(): Promise<void> {
  const defaultPath = outputPathInput.value.trim() || normalizeOutputPath(imagePathInput.value.trim(), currentOutputFormat());
  setStatus('Opening output path dialog...');
  const response = await window.ginga.saveImageDialog({
    defaultPath,
    format: currentOutputFormat()
  });
  if (response.canceled) {
    setStatus('Output path selection canceled.');
    return;
  }

  outputPathInput.value = response.filePath;
  setStatus('Output path selected.');
}

async function convertImage(): Promise<void> {
  const inputPath = imagePathInput.value.trim();
  const outputPath = outputPathInput.value.trim();
  if (!inputPath || !outputPath) {
    setStatus('Enter both input and output paths before converting.');
    setResult({ ok: false, error: 'Missing conversion path' });
    replaceDetails([['Mode', 'Convert'], ['Status', 'Missing input or output path']]);
    return;
  }

  const quality = currentOutputFormat() === 'jpg' || currentOutputFormat() === 'jpeg' ? parseQuality() : 90;
  convertButton.disabled = true;
  try {
    setStatus('Running convert...');
    const outcome = (await window.ginga.convertImage(inputPath, outputPath, quality)) as ConvertBridgeOutcome;
    if (!outcome.ok) {
      replaceDetails([
        ['Mode', 'Convert'],
        ['Status', 'Failed'],
        ['Error', outcome.error?.message ?? 'Unknown conversion failure']
      ]);
      setResult({
        ok: false,
        error: outcome.error ?? { message: 'Unknown conversion failure' }
      });
      setStatus('Convert failed.');
      return;
    }

    renderConversionDetails(outcome.response.details);
    setResult(summarizeConversionResponse(outcome.response));
    setStatus('Convert completed.');
  } finally {
    convertButton.disabled = false;
  }
}

async function chooseBatchImages(): Promise<void> {
  setStatus('Opening batch image dialog...');
  const response = await window.ginga.openBatchImageDialog();
  if (response.canceled) {
    setStatus('Batch image selection canceled.');
    return;
  }

  if (response.filePaths.length === 0) {
    batchSelection = [];
    updateBatchSummary();
    setStatus('No supported images were selected.');
    return;
  }

  const inputFormat = inferInputFormat(response.filePaths[0]);
  const mismatched = response.filePaths.some((filePath) => inferInputFormat(filePath) !== inputFormat);
  if (mismatched || !inputFormat) {
    batchSelection = [];
    updateBatchSummary();
    replaceDetails([
      ['Mode', 'Batch convert'],
      ['Status', 'Selection rejected'],
      ['Reason', 'Batch selections must all use the same input format']
    ]);
    setResult({ ok: false, error: 'Batch selections must use the same input format' });
    setStatus('Batch selection rejected.');
    return;
  }

  batchSelection = response.filePaths;
  updateBatchSummary();
  if (!imagePathInput.value.trim()) {
    clearGallery();
    setCurrentImagePath(batchSelection[0]);
    await renderPath(batchSelection[0]);
  } else {
    setStatus('Batch images selected.');
  }
}

async function batchConvert(): Promise<void> {
  if (batchSelection.length === 0) {
    setStatus('Choose batch images before converting.');
    replaceDetails([['Mode', 'Batch convert'], ['Status', 'Missing batch selection']]);
    setResult({ ok: false, error: 'Missing batch selection' });
    return;
  }

  const inputFormat = inferInputFormat(batchSelection[0]) ?? 'unknown';

  const outputDirectory = await window.ginga.openDirectoryDialog();
  if (outputDirectory.canceled) {
    setStatus('Batch output folder selection canceled.');
    return;
  }

  const outputFormat = currentOutputFormat();
  const quality = outputFormat === 'jpg' || outputFormat === 'jpeg' ? parseQuality() : 90;
  const results: BatchItemSummary[] = [];

  batchConvertButton.disabled = true;
  try {
    setStatus(`Running batch convert for ${batchSelection.length} image(s)...`);
    let batchIndex = 0;
    async function convertNext(): Promise<void> {
      while (batchIndex < batchSelection.length) {
        const i = batchIndex++;
        const inputPath = batchSelection[i];
        const outputPath = buildBatchOutputPath(inputPath, outputDirectory.directoryPath, outputFormat);
        try {
          const outcome = (await window.ginga.convertImage(inputPath, outputPath, quality)) as ConvertBridgeOutcome;
          if (!outcome.ok) {
            results.push({
              inputPath,
              outputPath,
              ok: false,
              compressionRatio: null,
              error: outcome.error?.message ?? 'Unknown conversion failure'
            });
            continue;
          }

          results.push({
            inputPath,
            outputPath,
            ok: true,
            compressionRatio: outcome.response.details.compressionRatio
          });
        } catch (error) {
          results.push({
            inputPath,
            outputPath,
            ok: false,
            compressionRatio: null,
            error: error instanceof Error ? error.message : String(error)
          });
        }
      }
    }
    await Promise.all(
      Array.from({ length: Math.min(4, batchSelection.length) }, () => convertNext())
    );
  } finally {
    batchConvertButton.disabled = false;
  }

  const succeeded = results.filter((item) => item.ok).length;
  const failed = results.length - succeeded;
  replaceDetails([
    ['Mode', 'Batch convert'],
    ['Files', String(results.length)],
    ['Input format', inputFormat],
    ['Output format', outputFormat],
    ['Output folder', outputDirectory.directoryPath],
    ['Succeeded', String(succeeded)],
    ['Failed', String(failed)],
    ['Quality', outputFormat === 'jpg' || outputFormat === 'jpeg' ? String(quality) : 'n/a']
  ]);
  setResult({
    ok: failed === 0,
    mode: 'batch-convert',
    inputFormat,
    outputFormat,
    outputDirectory: outputDirectory.directoryPath,
    files: results.length,
    succeeded,
    failed,
    items: results
  });
  setStatus(failed === 0 ? 'Batch convert completed.' : `Batch convert finished with ${failed} failed item(s).`);
}

function handleSwipeStart(event: PointerEvent): void {
  swipeStartX = event.clientX;
}

function handleSwipeEnd(event: PointerEvent): void {
  if (swipeStartX === null || galleryState.filePaths.length <= 1) {
    swipeStartX = null;
    return;
  }

  const deltaX = event.clientX - swipeStartX;
  swipeStartX = null;

  if (Math.abs(deltaX) < 48) {
    return;
  }

  if (deltaX < 0) {
    withAsyncStatus(() => navigateGallery(1))();
  } else {
    withAsyncStatus(() => navigateGallery(-1))();
  }
}

function handleKeyboardNavigation(event: KeyboardEvent): void {
  const target = event.target;
  if (target instanceof HTMLInputElement || target instanceof HTMLSelectElement || target instanceof HTMLTextAreaElement) {
    return;
  }

  if (galleryState.filePaths.length <= 1) {
    return;
  }

  if (event.key === 'ArrowLeft') {
    event.preventDefault();
    withAsyncStatus(() => navigateGallery(-1))();
  } else if (event.key === 'ArrowRight') {
    event.preventDefault();
    withAsyncStatus(() => navigateGallery(1))();
  }
}

browseButton.addEventListener('click', withAsyncStatus(chooseImage));
browseFolderButton.addEventListener('click', withAsyncStatus(chooseFolder));
inspectButton.addEventListener('click', withAsyncStatus(inspectCurrentImage));
browseOutputButton.addEventListener('click', withAsyncStatus(chooseOutput));
browseBatchButton.addEventListener('click', withAsyncStatus(chooseBatchImages));
convertButton.addEventListener('click', withAsyncStatus(convertImage));
batchConvertButton.addEventListener('click', withAsyncStatus(batchConvert));
previousImageButton.addEventListener('click', withAsyncStatus(() => navigateGallery(-1)));
nextImageButton.addEventListener('click', withAsyncStatus(() => navigateGallery(1)));
outputFormatSelect.addEventListener('change', syncOutputControls);
imagePathInput.addEventListener('change', withAsyncStatus(handleManualImagePathCommit));
imagePathInput.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') {
    event.preventDefault();
    withAsyncStatus(handleManualImagePathCommit)();
  }
});
previewFrameNode.addEventListener('pointerdown', handleSwipeStart);
previewFrameNode.addEventListener('pointerup', handleSwipeEnd);
previewFrameNode.addEventListener('pointercancel', () => {
  swipeStartX = null;
});
document.addEventListener('keydown', handleKeyboardNavigation);

updateGallerySummary();
updateBatchSummary();
syncOutputControls();
clearPreview('Load a file or a folder. The first image renders as soon as it is selected.');
