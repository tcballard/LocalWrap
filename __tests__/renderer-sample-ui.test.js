class FakeClassList {
  constructor() {
    this.values = new Set();
  }

  add(...names) {
    names.forEach((name) => this.values.add(name));
  }

  remove(...names) {
    names.forEach((name) => this.values.delete(name));
  }

  toggle(name, force) {
    const shouldAdd = force === undefined ? !this.values.has(name) : Boolean(force);
    if (shouldAdd) {
      this.values.add(name);
    } else {
      this.values.delete(name);
    }
  }

  contains(name) {
    return this.values.has(name);
  }
}

class FakeElement {
  constructor(id) {
    this.id = id;
    this.children = [];
    this.classList = new FakeClassList();
    this.dataset = {};
    this.listeners = {};
    this.style = {};
    this.checked = false;
    this.className = '';
    this.disabled = false;
    this.hidden = false;
    this.innerHTML = '';
    this.scrollHeight = 0;
    this.scrollTop = 0;
    this.textContent = '';
    this.value = '';
  }

  addEventListener(type, callback) {
    this.listeners[type] = callback;
  }

  appendChild(child) {
    this.children.push(child);
    return child;
  }

  closest() {
    return null;
  }

  getBoundingClientRect() {
    return {
      x: 0,
      y: 0,
      width: 320,
      height: 240,
    };
  }
}

function createFakeDom() {
  const elements = new Map();
  const windowListeners = {};

  const document = {
    createElement: (tagName) => new FakeElement(tagName),
    getElementById: (id) => {
      if (!elements.has(id)) {
        elements.set(id, new FakeElement(id));
      }

      return elements.get(id);
    },
  };

  const window = {
    addEventListener: (type, callback) => {
      windowListeners[type] = callback;
    },
    confirm: jest.fn(() => true),
    requestAnimationFrame: (callback) => callback(),
  };

  return {
    document,
    elements,
    window,
    windowListeners,
  };
}

async function flushPromises() {
  await Promise.resolve();
  await Promise.resolve();
}

describe('renderer sample project action', () => {
  afterEach(() => {
    delete global.document;
    delete global.window;
    delete global.LocalWrapRenderer;
    jest.resetModules();
  });

  test('creates, selects, and renders the sample project without starting it', async () => {
    jest.resetModules();

    const sample = {
      id: 'sample-1',
      name: 'localwrap-sample-project',
      cwd: '/tmp/LocalWrap/sample-projects/localwrap-sample-project',
      command: 'npm run dev',
      port: 3000,
      url: 'http://localhost:3000',
      autostart: false,
      openOnReady: false,
      isSample: true,
      runtime: {
        status: 'stopped',
        logs: [],
      },
    };
    let projects = [];
    const api = {
      closeProjectPreview: jest.fn(() => Promise.resolve(true)),
      createSampleProject: jest.fn(async () => {
        projects = [sample];
        return sample;
      }),
      diagnoseProjectDraft: jest.fn(async () => ({
        status: 'pass',
        summary: 'Ready to start.',
        checks: [],
        timeline: [{ message: 'Ready to start.' }],
      })),
      discoverScripts: jest.fn(async () => []),
      listProjects: jest.fn(async () => projects),
      onPreviewEvent: jest.fn(),
      onProjectEvent: jest.fn(),
      onProjectListChanged: jest.fn(),
      validateProjectDraft: jest.fn(async () => ({
        valid: true,
        errors: [],
        warnings: [],
      })),
    };
    const dom = createFakeDom();
    dom.window.localwrapAPI = api;
    global.document = dom.document;
    global.window = dom.window;

    // In the app, a script tag loads shared-constants.js before app.js.
    globalThis.LocalWrapConstants = require('../public/shared-constants');
    require('../public/app.js');
    dom.windowListeners.DOMContentLoaded();
    await flushPromises();

    await dom.elements.get('emptySampleProjectBtn').listeners.click();
    await flushPromises();

    expect(api.createSampleProject).toHaveBeenCalledTimes(1);
    expect(api.listProjects).toHaveBeenCalledTimes(2);
    expect(api.closeProjectPreview).toHaveBeenCalled();
    expect(dom.elements.get('projectDetail').hidden).toBe(false);
    expect(dom.elements.get('emptyState').classList.contains('visible')).toBe(false);
    expect(dom.elements.get('nameInput').value).toBe(sample.name);
    expect(dom.elements.get('cwdInput').value).toBe(sample.cwd);
    expect(dom.elements.get('commandInput').value).toBe('npm run dev');
    expect(dom.elements.get('portInput').value).toBe(3000);
    expect(dom.elements.get('urlInput').value).toBe('http://localhost:3000');
    expect(dom.elements.get('startProjectBtn').disabled).toBe(false);
    expect(dom.elements.get('statusBar').textContent).toBe(
      'Sample project ready. Click Save & Start.'
    );
  });
});
