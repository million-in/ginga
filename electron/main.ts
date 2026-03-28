import { app, BrowserWindow, dialog, ipcMain, Menu } from 'electron';
import * as path from 'node:path';
import { pathToFileURL } from 'node:url';

import type {
  OpenImageDialogResult,
  PreviewBridgeError,
  PreviewBridgeOutcome,
  PreviewEngineResponse
} from './shared';

type PreviewBridgeModule = {
  previewImage(input: {
    imagePath: string;
    binaryPath?: string;
  }): Promise<PreviewEngineResponse>;
};

let bridgePromise: Promise<PreviewBridgeModule> | null = null;
let mainWindow: BrowserWindow | null = null;

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

async function openImageDialog(): Promise<OpenImageDialogResult> {
  const result = await dialog.showOpenDialog({
    properties: ['openFile'],
    title: 'Open image',
    filters: [
      { name: 'Images', extensions: ['png', 'jpg', 'jpeg'] },
      { name: 'All files', extensions: ['*'] }
    ]
  });

  if (result.canceled || result.filePaths.length === 0) {
    return { canceled: true, filePath: '' };
  }

  return { canceled: false, filePath: result.filePaths[0] };
}

function createWindow(): void {
  const paths = resolveAppPaths();
  mainWindow = new BrowserWindow({
    width: 1120,
    height: 760,
    minWidth: 920,
    minHeight: 640,
    backgroundColor: '#07111f',
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
  ipcMain.handle('ginga:preview-image', previewImage);
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
  createWindow();
}

boot().catch((error: unknown) => {
  console.error('Failed to start ginga:', error);
  process.exitCode = 1;
});
