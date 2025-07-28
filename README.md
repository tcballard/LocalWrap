# LocalWrap

A secure desktop wrapper for localhost development servers.

## Quick Start

```bash
# Install dependencies
npm install

# Start development mode
npm run dev

# Start production mode
npm start

# Build for distribution
npm run dist
```

## Features

- **Secure**: Context isolation, CSP headers, rate limiting
- **Cross-platform**: Windows, macOS, Linux
- **System tray**: Minimize to tray with context menu
- **Development ready**: Express server with security middleware

## Project Structure

```
LocalWrap/
├── main.js                 # Electron main process
├── preload.js              # Secure IPC bridge
├── public/                 # Web application files
├── assets/                 # App icons
└── package.json            # Configuration
```

## Security

- Context isolation enabled
- Content Security Policy headers
- Request rate limiting
- Input validation
- Single instance enforcement

## License

MIT
