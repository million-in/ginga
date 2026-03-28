import { contextBridge, ipcRenderer } from 'electron';

import type {
  ConvertBridgeOutcome,
  GingaApi,
  InspectBridgeOutcome,
  OpenBatchImageDialogResult,
  OpenDirectoryDialogResult,
  OpenImageDialogResult,
  OpenImageFolderDialogResult,
  PreviewBridgeOutcome,
  SaveImageDialogOptions,
  SaveImageDialogResult
} from './shared';

async function openImageDialog(): Promise<OpenImageDialogResult> {
  return ipcRenderer.invoke('ginga:open-image-dialog') as Promise<OpenImageDialogResult>;
}

async function openImageFolderDialog(): Promise<OpenImageFolderDialogResult> {
  return ipcRenderer.invoke('ginga:open-image-folder-dialog') as Promise<OpenImageFolderDialogResult>;
}

async function openBatchImageDialog(): Promise<OpenBatchImageDialogResult> {
  return ipcRenderer.invoke('ginga:open-batch-image-dialog') as Promise<OpenBatchImageDialogResult>;
}

async function openDirectoryDialog(): Promise<OpenDirectoryDialogResult> {
  return ipcRenderer.invoke('ginga:open-directory-dialog') as Promise<OpenDirectoryDialogResult>;
}

async function saveImageDialog(options: SaveImageDialogOptions): Promise<SaveImageDialogResult> {
  return ipcRenderer.invoke('ginga:save-image-dialog', options) as Promise<SaveImageDialogResult>;
}

async function previewImage(imagePath: string): Promise<PreviewBridgeOutcome> {
  return ipcRenderer.invoke('ginga:preview-image', imagePath) as Promise<PreviewBridgeOutcome>;
}

async function inspectImage(imagePath: string): Promise<InspectBridgeOutcome> {
  return ipcRenderer.invoke('ginga:inspect-image', imagePath) as Promise<InspectBridgeOutcome>;
}

async function convertImage(
  inputPath: string,
  outputPath: string,
  quality: number
): Promise<ConvertBridgeOutcome> {
  return ipcRenderer.invoke('ginga:convert-image', { inputPath, outputPath, quality }) as Promise<ConvertBridgeOutcome>;
}

const api: GingaApi = Object.freeze({
  openImageDialog,
  openImageFolderDialog,
  openBatchImageDialog,
  openDirectoryDialog,
  saveImageDialog,
  previewImage,
  inspectImage,
  convertImage
});

contextBridge.exposeInMainWorld('ginga', api);
