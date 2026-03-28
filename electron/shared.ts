export interface OpenImageDialogResult {
  canceled: boolean;
  filePath: string;
}

export interface PreviewEngineRequest {
  command: 'preview';
  imagePath: string;
}

export interface PreviewEnginePayload {
  ok?: boolean;
  format?: string;
  sourceWidth?: number;
  sourceHeight?: number;
  previewWidth?: number;
  previewHeight?: number;
  previewPngBase64?: string;
}

export interface PreviewEngineResponse {
  binaryPath: string;
  command: string[];
  request: PreviewEngineRequest;
  payload: PreviewEnginePayload;
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

export interface GingaApi {
  openImageDialog(): Promise<OpenImageDialogResult>;
  previewImage(imagePath: string): Promise<PreviewBridgeOutcome>;
}

declare global {
  interface Window {
    ginga: GingaApi;
  }
}

export {};
