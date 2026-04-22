export interface OpenImageDialogResult {
  canceled: boolean;
  filePath: string;
}

export interface OpenImageFolderDialogResult {
  canceled: boolean;
  directoryPath: string;
  filePaths: string[];
}

export interface OpenBatchImageDialogResult {
  canceled: boolean;
  filePaths: string[];
}

export interface OpenDirectoryDialogResult {
  canceled: boolean;
  directoryPath: string;
}

export type OutputFormat = 'png' | 'jpg' | 'jpeg' | 'webp' | 'spd';

export interface SaveImageDialogOptions {
  defaultPath?: string;
  format: OutputFormat;
}

export interface SaveImageDialogResult {
  canceled: boolean;
  filePath: string;
}

export interface PreviewEngineRequest {
  command: 'preview';
  imagePath: string;
  spectralMode?: 'none' | 'approximate' | 'native';
}

export interface ConvertEngineRequest {
  command: 'convert';
  inputPath: string;
  outputPath: string;
  quality?: number;
}

export interface PreviewEnginePayload {
  ok?: boolean;
  format?: string;
  sourceWidth?: number;
  sourceHeight?: number;
  previewWidth?: number;
  previewHeight?: number;
  previewMimeType?: string;
  animated?: boolean;
  previewImageBase64?: string;
}

export interface PreviewEngineResponse {
  binaryPath: string;
  command: string[];
  request: PreviewEngineRequest;
  payload: PreviewEnginePayload;
  stderr: string;
}

export interface PngInspectPayload {
  ok: true;
  format: 'png';
  width: number;
  height: number;
}

export interface JpegInspectPayload {
  ok: true;
  format: 'jpeg';
  width: number;
  height: number;
  precision: number;
  components: number;
  baseline: boolean;
  progressive: boolean;
  lossless: boolean;
  arithmeticCoding: boolean;
  quantizationTables: number;
  huffmanDcTables: number;
  huffmanAcTables: number;
  restartInterval: number;
  scanCount: number;
  jfif: boolean;
  adobe: boolean;
}

export interface SpdInspectPayload {
  ok: true;
  format: 'spd';
  width: number;
  height: number;
  sampleCount: number;
  lambdaMinNm: number;
  lambdaStepNm: number;
}

export interface GifInspectPayload {
  ok: true;
  format: 'gif';
  width: number;
  height: number;
  frameCount: number;
  hasTransparency: boolean;
}

export interface WebpInspectPayload {
  ok: true;
  format: 'webp';
  width: number;
  height: number;
  isLossy: boolean;
  hasAlpha: boolean;
}

export type InspectEnginePayload = PngInspectPayload | JpegInspectPayload | GifInspectPayload | WebpInspectPayload | SpdInspectPayload;

export interface InspectEngineResponse {
  binaryPath: string;
  command: string[];
  imagePath: string;
  payload: InspectEnginePayload;
  stderr: string;
}

export interface ConversionDetails {
  sourcePath: string;
  outputPath: string;
  sourceFormat: string;
  outputFormat: string;
  sourceWidth: number;
  sourceHeight: number;
  outputWidth: number;
  outputHeight: number;
  sourceBytes: number;
  outputBytes: number;
  compressionRatio: number | null;
  outputEncoding: 'lossless' | 'lossy';
  quality: number | null;
}

export interface ConvertEngineResponse {
  binaryPath: string;
  command: string[];
  request: ConvertEngineRequest;
  source: InspectEngineResponse;
  output: InspectEngineResponse;
  details: ConversionDetails;
  stderr: string;
}

export interface PreviewBridgeError {
  message: string;
  code: string;
  details: unknown;
  stdout: string;
  stderr: string;
  binaryPath: string;
}

export interface PreviewBridgeSuccess {
  ok: true;
  response: PreviewEngineResponse;
}

export interface PreviewBridgeFailure {
  ok: false;
  error: PreviewBridgeError;
}

export type PreviewBridgeOutcome = PreviewBridgeSuccess | PreviewBridgeFailure;

export interface InspectBridgeSuccess {
  ok: true;
  response: InspectEngineResponse;
}

export interface InspectBridgeFailure {
  ok: false;
  error: PreviewBridgeError;
}

export type InspectBridgeOutcome = InspectBridgeSuccess | InspectBridgeFailure;

export interface ConvertBridgeSuccess {
  ok: true;
  response: ConvertEngineResponse;
}

export interface ConvertBridgeFailure {
  ok: false;
  error: PreviewBridgeError;
}

export type ConvertBridgeOutcome = ConvertBridgeSuccess | ConvertBridgeFailure;

export interface GingaApi {
  openImageDialog(): Promise<OpenImageDialogResult>;
  openImageFolderDialog(): Promise<OpenImageFolderDialogResult>;
  openBatchImageDialog(): Promise<OpenBatchImageDialogResult>;
  openDirectoryDialog(): Promise<OpenDirectoryDialogResult>;
  saveImageDialog(options: SaveImageDialogOptions): Promise<SaveImageDialogResult>;
  previewImage(imagePath: string): Promise<PreviewBridgeOutcome>;
  inspectImage(imagePath: string): Promise<InspectBridgeOutcome>;
  convertImage(inputPath: string, outputPath: string, quality: number): Promise<ConvertBridgeOutcome>;
}

declare global {
  interface Window {
    ginga: GingaApi;
  }
}

export {};
