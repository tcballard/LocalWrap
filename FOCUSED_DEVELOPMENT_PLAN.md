# LocalWrap Focused Development Plan

## Core User Requirements
- **Script Execution**: Run development scripts (npm start, yarn dev, python server, etc.)
- **Port Targeting**: Target any localhost port for development
- **Desktop App**: Windows desktop application interface
- **Local Dev Server**: Run local development server on localhost:3000 (or any port)
- **Web-to-Desktop**: Convert localhost web apps into standalone desktop applications

## Current LocalWrap Capabilities
✅ Electron-based Windows desktop app  
✅ Express server on configurable ports  
✅ Multi-server port management  
✅ Windows 95-style UI theme  
✅ System tray integration  
✅ Security features (CSP, rate limiting, input validation)  

❌ **Missing**: Script execution capability  
❌ **Missing**: Web-to-desktop app conversion  

## Focused Implementation Plan

### Phase 1: Script Runner Integration (Week 1)

#### 1.1 Script Execution Interface
- Add script input field to main UI
- Support for common development commands:
  - `npm start`, `npm run dev`
  - `yarn start`, `yarn dev`
  - `python -m http.server 3000`
  - `python -m http.server 8000`
  - `php -S localhost:3000`
  - Custom shell commands
- Real-time script output display in embedded terminal view

#### 1.2 Process Management
- Start/stop/restart script processes
- Process status monitoring
- Handle script failures and restarts
- Kill processes when app closes

#### 1.3 UI Enhancements
- Add "Script" input field above port selection
- Terminal output window (collapsible)
- Process status indicators
- Script history dropdown for commonly used commands

### Phase 2: Enhanced Port & Desktop Conversion (Week 2)

#### 2.1 Improved Port Management
- Auto-detect services running on ports
- Port conflict resolution
- Quick port switching (3000, 3001, 8000, 8080 presets)
- Real-time port availability checking

#### 2.2 Web-to-Desktop App Conversion
- "Create Desktop App" button for active localhost servers
- Generate standalone Electron app wrappers:
  - Custom app name and icon
  - Embedded web view pointing to localhost URL
  - Save generated apps to user's Applications folder
- App template management (React, Vue, Angular presets)

#### 2.3 Workflow Simplification
- Streamlined 3-step process:
  1. Enter script command
  2. Select target port
  3. Launch → Auto-create desktop app
- Remove complex server management UI
- Focus on single-server workflow

## Technical Implementation Details

### Script Execution
- Use Node.js `child_process.spawn()` for script execution
- Capture stdout/stderr for terminal display
- Handle different script types (npm, yarn, python, php, etc.)
- Working directory selection for script execution

### Desktop App Generation
- Create Electron app template with minimal configuration
- Dynamic HTML generation pointing to localhost URL
- Package apps with electron-builder for distribution
- Store generated apps in user-defined directory

### UI Modifications
- Modify `/public/app.html` to include script runner interface
- Add terminal component for output display
- Simplify server management to single-server focus
- Maintain Windows 95 aesthetic

## Success Metrics
- ✅ Can execute `npm start` and see output in terminal
- ✅ Can target localhost:3000 and other ports
- ✅ Can generate standalone desktop app from running localhost server
- ✅ Generated desktop apps work independently
- ✅ Simple 3-step workflow: Script → Port → Desktop App

## Future Considerations (Post-Core Implementation)
- Script templates and presets
- Project folder integration
- Multiple simultaneous scripts
- Cloud sync of configurations
- Monetization through premium templates and features