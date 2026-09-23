#ifndef HO_SCRIPT_BRIDGE_JS_H_7PWM4R1C
#define HO_SCRIPT_BRIDGE_JS_H_7PWM4R1C

// The TextMate object exposed to command output (injected at document start). It is compatible with the
// WebView-based implementation (HOJSBridge.mm):
//
//   TextMate.system(command, handler)  Run a shell command. With a handler it is asynchronous and returns a
//                                      command object; the handler is called with it when the command is done.
//                                      Without a handler (or null) it is synchronous and returns the result.
//   TextMate.log(message)              Write a message to the system log.
//   TextMate.open(path, options)       Open a file in TextMate; options is a line number or a selection string.
//   TextMate.isBusy                    Show the busy indicator.
//   TextMate.progress                  Value of the progress indicator (0–1).
//
// Command objects have outputString, errorString, status, onreadoutput, onreaderror, write(str), close(),
// and cancel(). When onreadoutput/onreaderror is set, outputString/errorString only hold the last output.
//
// The native side (HOScriptBridge) also verifies the origin of every message and request.

static char const* const kHOScriptBridgeJavaScript = R"JS(
(function () {
	if(!['x-txmt-filehandle:', 'tm-file:'].includes(location.protocol) || !window.webkit || !window.webkit.messageHandlers.textmate)
		return;

	const post     = (message) => window.webkit.messageHandlers.textmate.postMessage(message);
	const commands = new Map();
	// Command IDs are unique across pages and frames, as the native side does not get a stable frame identity
	const idPrefix = Math.random().toString(36).slice(2) + Date.now().toString(36) + '-';
	let nextId = 1, busy = false, progress = 0;

	class Command {
		constructor (id, handler) {
			this._id      = id;
			this._handler = handler;
			this._onreadoutput = null;
			this._onreaderror  = null;
			this.outputString = '';
			this.errorString  = '';
			this.status       = undefined;
		}

		get onreadoutput ()    { return this._onreadoutput; }
		set onreadoutput (fn)  { this._onreadoutput = fn; if(fn) fn.call(fn, this.outputString); }
		get onreaderror ()     { return this._onreaderror; }
		set onreaderror (fn)   { this._onreaderror = fn; if(fn) fn.call(fn, this.errorString); }

		write (str) { if(this._id) post({ type: 'write', id: this._id, data: String(str) }); }
		close ()    { if(this._id) post({ type: 'close', id: this._id }); }
		cancel ()   {
			if(!this._id)
				return;
			post({ type: 'cancel', id: this._id });
			commands.delete(this._id);
			this._id = this._handler = this._onreadoutput = this._onreaderror = null;
		}

		_event (kind, value) {
			if(kind == 'output' || kind == 'error') {
				const handler = kind == 'output' ? this._onreadoutput : this._onreaderror;
				const key     = kind == 'output' ? 'outputString' : 'errorString';
				this[key] = handler ? value : this[key] + value;
				if(handler)
					handler.call(handler, value);
			} else if(kind == 'exit') {
				this.status = value;
				const handler = this._handler;
				commands.delete(this._id);
				this._id = null;
				if(handler)
					handler.call(handler, this);
			}
		}
	}

	function system (command, handler) {
		command = String(command);
		if(typeof handler != 'function') {
			const xhr = new XMLHttpRequest();
			xhr.open('POST', 'x-txmt-js://system', false);
			xhr.send(JSON.stringify({ command: command }));
			const result = new Command(null, null);
			if(xhr.status == 200)
				Object.assign(result, JSON.parse(xhr.responseText));
			else
				result.status = -1, result.errorString = 'TextMate.system() failed: ' + xhr.status;
			return result;
		}

		const id = idPrefix + nextId++;
		const cmd = new Command(id, handler);
		commands.set(id, cmd);
		post({ type: 'system', id: id, command: command });
		return cmd;
	}

	const TextMate = {
		system: system,
		log:    (message) => post({ type: 'log', message: String(message) }),
		open:   (path, options) => post({ type: 'open', path: String(path), options: options === undefined ? null : options }),

		get isBusy ()    { return busy; },
		set isBusy (v)   { busy = !!v; post({ type: 'busy', value: busy }); },
		get progress ()  { return progress; },
		set progress (v) { progress = Number(v) || 0; post({ type: 'progress', value: progress }); },

		// Called by the native side
		_commandEvent (id, kind, value) {
			const cmd = commands.get(id);
			if(cmd)
				cmd._event(kind, value);
		},
	};

	Object.defineProperty(window, 'TextMate', { value: TextMate, writable: false, configurable: false });
})();
)JS";

#endif /* end of include guard: HO_SCRIPT_BRIDGE_JS_H_7PWM4R1C */
