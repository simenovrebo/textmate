#ifndef HO_BROWSER_VIEW_JS_H_Q2N8XK5D
#define HO_BROWSER_VIEW_JS_H_Q2N8XK5D

// Injected into all pages and frames at document start (page world, so that it sees the page’s console calls).
// It replaces WebView delegate methods that have no WKWebView equivalent:
//
//   - Link under the mouse: posts { type: 'status', text } for the status bar (was mouseDidMoveOverElement:).
//   - Console messages and uncaught errors: posts { type: 'console', … } to be logged (was addMessageToConsole:).
//   - file:// URLs assigned from JavaScript (e.g. img.src = 'file://' + path in Bundle Support’s webpreview.js)
//     are changed to tm-file://, as WKWebView does not allow command output to load file:// URLs. URLs in the
//     HTML itself are rewritten by the scheme handlers (file_url_rewriter.h). Only for command output and
//     local files.

static char const* const kHOBrowserViewJavaScript = R"JS(
(function () {
	const handler = window.webkit && window.webkit.messageHandlers.textmateBrowser;
	if(!handler)
		return;
	const post = (message) => { try { handler.postMessage(message); } catch(e) { } };

	// ===============
	// = Status Text =
	// ===============

	let currentLink = null;
	const showLink = (link) => {
		if(link === currentLink)
			return;
		currentLink = link;
		const href = link ? link.href : '';
		post({ type: 'status', text: typeof href == 'string' ? href : (href && href.baseVal) || '' }); // SVG links have an SVGAnimatedString
	};
	document.addEventListener('mouseover', (e) => showLink(e.target instanceof Element ? e.target.closest('a[href], area[href]') : null), true);
	document.addEventListener('mouseout', (e) => { if(!e.relatedTarget) showLink(null); }, true);

	// ===========
	// = Console =
	// ===========

	const describe = (value) => {
		if(value instanceof Error)
			return value.stack ? value.message + '\n' + value.stack : String(value);
		if(typeof value == 'object' && value !== null) {
			try { return JSON.stringify(value); } catch(e) { }
		}
		return String(value);
	};

	for(const level of ['log', 'info', 'warn', 'error', 'debug']) {
		const original = console[level];
		console[level] = function (...args) {
			post({ type: 'console', level: level, message: args.map(describe).join(' '), url: location.href });
			return original.apply(this, args);
		};
	}

	window.addEventListener('error', (e) => {
		if(e.message)
			post({ type: 'console', level: 'error', message: e.message, url: e.filename || location.href, line: e.lineno });
	});

	// ==================================
	// = file:// URLs set by JavaScript =
	// ==================================

	if(!['x-txmt-filehandle:', 'tm-file:'].includes(location.protocol))
		return;

	const fix = (value) => typeof value == 'string' && /^file:\/\//i.test(value) ? 'tm-file://' + value.slice(7) : value;
	const properties = [
		[HTMLImageElement, 'src'], [HTMLScriptElement, 'src'], [HTMLIFrameElement, 'src'], [HTMLSourceElement, 'src'],
		[HTMLMediaElement, 'src'], [HTMLEmbedElement, 'src'], [HTMLLinkElement, 'href'], [HTMLAnchorElement, 'href'],
		[HTMLAreaElement, 'href'],
	];

	for(const [cls, property] of properties) {
		const descriptor = Object.getOwnPropertyDescriptor(cls.prototype, property);
		if(descriptor && descriptor.set)
			Object.defineProperty(cls.prototype, property, { get: descriptor.get, set: function (value) { descriptor.set.call(this, fix(value)); }, enumerable: descriptor.enumerable, configurable: true });
	}

	const setAttribute = Element.prototype.setAttribute;
	Element.prototype.setAttribute = function (name, value) {
		return setAttribute.call(this, name, /^(src|href)$/i.test(name) ? fix(value) : value);
	};

	const open = window.open;
	window.open = function (url, ...args) {
		return open.call(this, fix(url), ...args);
	};
})();
)JS";

// Keeps the page scrolled to the bottom while command output streams in, unless the user scrolls up
// (was HOAutoScroll). Evaluated in the client world when the command output page is committed.

static char const* const kHOAutoScrollJavaScript = R"JS(
(function () {
	const scrollingElement = () => document.scrollingElement || document.documentElement;
	const isAtBottom = () => {
		const element = scrollingElement();
		return !element || element.scrollTop + window.innerHeight >= element.scrollHeight - 2;
	};

	let stickToBottom = true, pending = false, resizeObserver = null;
	const update = () => {
		if(!resizeObserver && document.documentElement) {
			resizeObserver = new ResizeObserver(update);
			resizeObserver.observe(document.documentElement);
		}

		if(!stickToBottom || pending)
			return;

		pending = true;
		requestAnimationFrame(() => {
			pending = false;
			const element = scrollingElement();
			if(stickToBottom && element)
				element.scrollTop = element.scrollHeight;
		});
	};

	window.addEventListener('scroll', () => { stickToBottom = isAtBottom(); }, { passive: true }); // only the user and update() scroll
	window.addEventListener('resize', update);
	new MutationObserver(update).observe(document, { childList: true, subtree: true, characterData: true });
	update();
})();
)JS";

#endif /* end of include guard: HO_BROWSER_VIEW_JS_H_Q2N8XK5D */
