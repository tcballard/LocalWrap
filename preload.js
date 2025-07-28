/**
 * LocalWrap Minimal Preload Script
 * NO IPC communication - eliminates cloning errors
 */

// Minimal security cleanup
console.log('LocalWrap: Minimal preload script loaded');

// Basic security: Remove dangerous globals
delete window.require;
delete window.exports; 
delete window.module;

// Simple app info without IPC
window.localwrapAPI = {
  version: '1.0.0',
  platform: 'desktop',
  isElectron: true
};

console.log('LocalWrap: Clean preload completed - no IPC enabled');
