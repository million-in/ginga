import { contextBridge, ipcRenderer } from 'electron';

import type { GingaApi, OpenImageDialogResult, PreviewBridgeOutcome } from './shared';

async function openImageDialog(): Promise<OpenImageDialogResult> {
  return ipcRenderer.invoke('ginga:open-image-dialog') as Promise<OpenImageDialogResult>;
}

async function previewImage(imagePath: string): Promise<PreviewBridgeOutcome> {
  return ipcRenderer.invoke('ginga:preview-image', imagePath) as Promise<PreviewBridgeOutcome>;
}

const api: GingaApi = Object.freeze({
  openImageDialog,
  previewImage
});

contextBridge.exposeInMainWorld('ginga', api);
