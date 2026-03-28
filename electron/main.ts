import { app, BrowserWindow, dialog, ipcMain, Menu, nativeImage } from 'electron';
import { readdir } from 'node:fs/promises';
import * as path from 'node:path';
import { pathToFileURL } from 'node:url';

import type {
  ConvertBridgeOutcome,
  ConvertEngineResponse,
  InspectBridgeOutcome,
  InspectEngineResponse,
  OpenBatchImageDialogResult,
  OpenDirectoryDialogResult,
  OpenImageDialogResult,
  OpenImageFolderDialogResult,
  PreviewBridgeError,
  PreviewBridgeOutcome,
  PreviewEngineResponse,
  SaveImageDialogOptions,
  SaveImageDialogResult
} from './shared';

type PreviewBridgeModule = {
  previewImage(input: {
    imagePath: string;
    binaryPath?: string;
  }): Promise<PreviewEngineResponse>;
  inspectImage(input: {
    imagePath: string;
    binaryPath?: string;
  }): Promise<InspectEngineResponse>;
  convertImage(input: {
    inputPath: string;
    outputPath: string;
    quality?: number;
    binaryPath?: string;
  }): Promise<ConvertEngineResponse>;
};

let bridgePromise: Promise<PreviewBridgeModule> | null = null;
let mainWindow: BrowserWindow | null = null;
const supportedImageExtensions = new Set(['.png', '.jpg', '.jpeg', '.spd']);

function resolveAppPaths(): {
  repoRoot: string;
  electronRoot: string;
  desktopDistRoot: string;
} {
  const repoRoot = app.getAppPath();
  const electronRoot = path.join(repoRoot, 'electron');
  return {
    repoRoot,
    electronRoot,
    desktopDistRoot: path.join(electronRoot, 'dist')
  };
}

function resolveIconPath(): string {
  const { electronRoot } = resolveAppPaths();
  return path.join(electronRoot, 'logo', 'AppIcon.svg');
}

function loadBridge(): Promise<PreviewBridgeModule> {
  if (!bridgePromise) {
    const { repoRoot } = resolveAppPaths();
    const bridgeUrl = pathToFileURL(
      path.join(repoRoot, 'scripts', 'electron-bridge.mjs')
    ).href;
    bridgePromise = import(bridgeUrl) as Promise<PreviewBridgeModule>;
  }

  return bridgePromise;
}

function normalizeBridgeError(error: unknown): PreviewBridgeError {
  const fallback = {
    message: error instanceof Error ? error.message : String(error),
    code: 'UNKNOWN',
    details: null,
    stdout: '',
    stderr: '',
    binaryPath: ''
  } satisfies PreviewBridgeError;

  if (!error || typeof error !== 'object') {
    return fallback;
  }

  const candidate = error as Partial<PreviewBridgeError>;
  return {
    message: typeof candidate.message === 'string' ? candidate.message : fallback.message,
    code: typeof candidate.code === 'string' ? candidate.code : fallback.code,
    details: 'details' in candidate ? candidate.details ?? null : fallback.details,
    stdout: typeof candidate.stdout === 'string' ? candidate.stdout : fallback.stdout,
    stderr: typeof candidate.stderr === 'string' ? candidate.stderr : fallback.stderr,
    binaryPath:
      typeof candidate.binaryPath === 'string' ? candidate.binaryPath : fallback.binaryPath
  };
}

async function previewImage(
  _event: Electron.IpcMainInvokeEvent,
  imagePath: string
): Promise<PreviewBridgeOutcome> {
  const bridge = await loadBridge();

  try {
    const response = await bridge.previewImage({ imagePath });
    return { ok: true, response };
  } catch (error) {
    return { ok: false, error: normalizeBridgeError(error) };
  }
}

async function inspectImage(
  _event: Electron.IpcMainInvokeEvent,
  imagePath: string
): Promise<InspectBridgeOutcome> {
  const bridge = await loadBridge();

  try {
    const response = await bridge.inspectImage({ imagePath });
    return { ok: true, response };
  } catch (error) {
    return { ok: false, error: normalizeBridgeError(error) };
  }
}

async function convertImage(
  _event: Electron.IpcMainInvokeEvent,
  input: { inputPath: string; outputPath: string; quality: number }
): Promise<ConvertBridgeOutcome> {
  const bridge = await loadBridge();

  try {
    const response = await bridge.convertImage(input);
    return { ok: true, response };
  } catch (error) {
    return { ok: false, error: normalizeBridgeError(error) };
  }
}

async function openImageDialog(): Promise<OpenImageDialogResult> {
  const result = await dialog.showOpenDialog({
    properties: ['openFile'],
    title: 'Open image',
    filters: [
      { name: 'Images', extensions: ['png', 'jpg', 'jpeg', 'spd'] },
      { name: 'All files', extensions: ['*'] }
    ]
  });

  if (result.canceled || result.filePaths.length === 0) {
    return { canceled: true, filePath: '' };
  }

  return { canceled: false, filePath: result.filePaths[0] };
}

function isSupportedImagePath(filePath: string): boolean {
  return supportedImageExtensions.has(path.extname(filePath).toLowerCase());
}

async function openImageFolderDialog(): Promise<OpenImageFolderDialogResult> {
  const result = await dialog.showOpenDialog({
    properties: ['openDirectory'],
    title: 'Open image folder'
  });

  if (result.canceled || result.filePaths.length === 0) {
    return { canceled: true, directoryPath: '', filePaths: [] };
  }

  const directoryPath = result.filePaths[0];
  const entries = await readdir(directoryPath, { withFileTypes: true });
  const filePaths = entries
    .filter((entry) => entry.isFile())
    .map((entry) => path.join(directoryPath, entry.name))
    .filter(isSupportedImagePath)
    .sort((lhs, rhs) => lhs.localeCompare(rhs));

  return { canceled: false, directoryPath, filePaths };
}

async function openBatchImageDialog(): Promise<OpenBatchImageDialogResult> {
  const result = await dialog.showOpenDialog({
    properties: ['openFile', 'multiSelections'],
    title: 'Select images for batch convert',
    filters: [
      { name: 'Images', extensions: ['png', 'jpg', 'jpeg', 'spd'] },
      { name: 'All files', extensions: ['*'] }
    ]
  });

  if (result.canceled || result.filePaths.length === 0) {
    return { canceled: true, filePaths: [] };
  }

  return {
    canceled: false,
    filePaths: result.filePaths.filter(isSupportedImagePath).sort((lhs, rhs) => lhs.localeCompare(rhs))
  };
}

async function openDirectoryDialog(): Promise<OpenDirectoryDialogResult> {
  const result = await dialog.showOpenDialog({
    properties: ['openDirectory', 'createDirectory'],
    title: 'Choose output folder'
  });

  if (result.canceled || result.filePaths.length === 0) {
    return { canceled: true, directoryPath: '' };
  }

  return { canceled: false, directoryPath: result.filePaths[0] };
}

async function saveImageDialog(options: SaveImageDialogOptions): Promise<SaveImageDialogResult> {
  const extension = options.format === 'jpg' ? 'jpg' : options.format;
  const result = await dialog.showSaveDialog({
    title: 'Save converted image',
    defaultPath: options.defaultPath,
    filters: [
      {
        name:
          extension === 'png'
            ? 'PNG image'
            : extension === 'spd'
              ? 'SPD spectral raster'
              : 'JPEG image',
        extensions:
          extension === 'png'
            ? ['png']
            : extension === 'spd'
              ? ['spd']
              : ['jpg', 'jpeg']
      }
    ]
  });

  if (result.canceled || !result.filePath) {
    return { canceled: true, filePath: '' };
  }

  return { canceled: false, filePath: result.filePath };
}

function createWindow(): void {
  const paths = resolveAppPaths();
  const iconPath = resolveIconPath();
  mainWindow = new BrowserWindow({
    width: 1360,
    height: 920,
    minWidth: 1040,
    minHeight: 760,
    backgroundColor: '#f7f6f2',
    icon: iconPath,
    show: false,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(paths.desktopDistRoot, 'preload.js')
    }
  });

  mainWindow.removeMenu();
  mainWindow.once('ready-to-show', () => {
    mainWindow?.show();
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  mainWindow.webContents.on('will-navigate', (event) => {
    event.preventDefault();
  });

  mainWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  mainWindow.loadFile(path.join(paths.electronRoot, 'index.html'));
}

function registerIpc(): void {
  ipcMain.handle('ginga:open-image-dialog', openImageDialog);
  ipcMain.handle('ginga:open-image-folder-dialog', openImageFolderDialog);
  ipcMain.handle('ginga:open-batch-image-dialog', openBatchImageDialog);
  ipcMain.handle('ginga:open-directory-dialog', openDirectoryDialog);
  ipcMain.handle('ginga:save-image-dialog', (_event, options: SaveImageDialogOptions) => saveImageDialog(options));
  ipcMain.handle('ginga:preview-image', previewImage);
  ipcMain.handle('ginga:inspect-image', inspectImage);
  ipcMain.handle('ginga:convert-image', convertImage);
}

function wireAppLifecycle(): boolean {
  if (!app.requestSingleInstanceLock()) {
    app.quit();
    return false;
  }

  app.on('second-instance', () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) {
        mainWindow.restore();
      }
      mainWindow.focus();
    }
  });

  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') {
      app.quit();
    }
  });

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });

  return true;
}

async function boot(): Promise<void> {
  app.setName('ginga');
  Menu.setApplicationMenu(null);
  registerIpc();

  if (!wireAppLifecycle()) {
    return;
  }

  await app.whenReady();
  const appIcon = nativeImage.createFromPath(resolveIconPath());
  if (!appIcon.isEmpty() && process.platform === 'darwin') {
    app.dock?.setIcon(appIcon);
  }
  createWindow();
}

boot().catch((error: unknown) => {
  console.error('Failed to start ginga:', error);
  process.exitCode = 1;
});
