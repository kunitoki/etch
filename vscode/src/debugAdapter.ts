import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';
import * as net from 'net';
import { spawn, ChildProcess } from 'child_process';
import {
    DebugSession, InitializedEvent, TerminatedEvent, StoppedEvent, OutputEvent,
    Thread, StackFrame, Source
} from '@vscode/debugadapter';
import { DebugProtocol } from '@vscode/debugprotocol';

const outputChannel = vscode.window.createOutputChannel('Etch Debug Adapter');

function log(message: string) {
    const timestamp = new Date().toISOString();
    const logMessage = `[${timestamp}] ${message}`;
    outputChannel.appendLine(logMessage);
    console.log(`[Etch Debug Adapter] ${logMessage}`);
}

export class EtchDebugAdapterProvider implements vscode.DebugAdapterDescriptorFactory {

    createDebugAdapterDescriptor(
        session: vscode.DebugSession,
        executable: vscode.DebugAdapterExecutable | undefined
    ): vscode.ProviderResult<vscode.DebugAdapterDescriptor> {
        log('Creating inline debug adapter (not external executable)');
        log(`Session ID: ${session.id}, Type: ${session.type}, Name: ${session.name}`);
        log(`Session configuration: ${JSON.stringify(session.configuration, null, 2)}`);

        // Check if this is an attach request (remote debugging)
        if (session.configuration.request === 'attach') {
            log('Creating remote attach debug adapter');
            return new vscode.DebugAdapterInlineImplementation(new RemoteEtchDebugAdapter());
        }

        // Return an inline debug adapter for launch requests
        return new vscode.DebugAdapterInlineImplementation(new EtchDebugAdapter());
    }
}

class EtchDebugAdapter extends DebugSession {
    private static THREAD_ID = 1;
    private etchProcess: ChildProcess | undefined;
    private nextSeq = 1;
    private currentFile: string = '';
    private currentLine: number = 0;
    private initialized = false;
    private pendingRequests: Array<{command: string, args: any, response?: any}> = [];

    // Pending responses waiting for Etch server replies
    // Use Maps to handle multiple concurrent requests (e.g., Locals and Globals requested simultaneously)
    private pendingStackTraceResponses: Map<number, DebugProtocol.StackTraceResponse> = new Map();
    private pendingVariablesResponses: Map<number, DebugProtocol.VariablesResponse> = new Map();
    private pendingScopesResponses: Map<number, DebugProtocol.ScopesResponse> = new Map();
    private pendingCustomResponses: Map<string, any> = new Map();

    constructor() {
        super();
        log('EtchDebugAdapter created');
        // IMPORTANT: Etch uses 1-based lines
        this.setDebuggerLinesStartAt1(true);
        this.setDebuggerColumnsStartAt1(true);
    }

    protected initializeRequest(response: DebugProtocol.InitializeResponse, args: DebugProtocol.InitializeRequestArguments): void {
        log('Handling initialize request - will be forwarded to Etch when process starts');

        // Store the capabilities that we support
        response.body = response.body || {};
        response.body.supportsConfigurationDoneRequest = true;
        response.body.supportsBreakpointLocationsRequest = false;
        response.body.supportsStepBack = false;
        response.body.supportsRestartFrame = false;
        response.body.supportsTerminateRequest = true;
        response.body.supportsSetVariable = true;

        this.sendResponse(response);
        this.sendEvent(new InitializedEvent());
        log('Sent initialize response and initialized event');
    }


    protected launchRequest(response: DebugProtocol.LaunchResponse, args: DebugProtocol.LaunchRequestArguments): void {
        log('Handling launch request');
        log(`Launch args: ${JSON.stringify(args, null, 2)}`);

        const launchArgs = args as any;
        const program = launchArgs.program;
        const debugExecutable = launchArgs.debugExecutable;
        log(`Program path: ${program}`);
        log(`Debug executable: ${debugExecutable || '(default: etch compiler)'}`);

        const workspaceFolder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(program));
        const workspacePath = workspaceFolder?.uri.fsPath || vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;

        if (!workspacePath) {
            log('ERROR: No workspace folder found');
            this.sendErrorResponse(response, 2001, 'No workspace folder found');
            return;
        }

        // Determine which executable to use
        let executablePath: string;
        let executableArgs: string[];

        if (debugExecutable && debugExecutable.trim() !== '') {
            // Use custom debug executable (C binary embedding Etch)
            executablePath = debugExecutable;
            executableArgs = [program];
            log(`Using custom debug executable: ${executablePath} ${program}`);
        } else {
            // Use default Etch compiler debug server
            executablePath = path.join(workspacePath, 'bin', 'etch');
            executableArgs = ['--debug-server', program];
            log(`Using Etch compiler debug server: ${executablePath} --debug-server ${program}`);
        }

        log(`Attempting to launch: ${executablePath} ${executableArgs.join(' ')}`);

        try {
            // Spawn the debug server process
            this.etchProcess = spawn(executablePath, executableArgs, {
                cwd: workspacePath,
                stdio: ['pipe', 'pipe', 'pipe']
            });

            log(`Etch process spawned with PID: ${this.etchProcess.pid}`);

            // Handle process events
            this.etchProcess.on('error', (error) => {
                log(`Etch process error: ${error.message}`);
                this.sendErrorResponse(response, 2002, `Failed to launch Etch: ${error.message}`);
            });

            this.etchProcess.on('exit', (code, signal) => {
                log(`Etch process exited with code ${code}, signal ${signal}`);
                this.sendEvent(new TerminatedEvent());
            });

            // Handle stdout - DAP messages from Etch debug server
            let stdoutBuffer = '';
            this.etchProcess.stdout?.on('data', (data) => {
                stdoutBuffer += data.toString();

                // Process complete JSON messages (one per line)
                const lines = stdoutBuffer.split('\n');
                stdoutBuffer = lines.pop() || ''; // Keep incomplete line in buffer

                for (const line of lines) {
                    if (line.trim()) {
                        try {
                            const message = JSON.parse(line.trim());
                            log(`Received from Etch: ${JSON.stringify(message, null, 2)}`);
                            this.handleEtchMessage(message);
                        } catch (e) {
                            log(`Failed to parse JSON from Etch: ${line.trim()}: ${e}`);
                        }
                    }
                }
            });

            // Handle stderr - debug output from Etch
            this.etchProcess.stderr?.on('data', (data) => {
                const output = data.toString();
                log(`Etch stderr: ${output.trim()}`);
            });

            // Send success response
            this.sendResponse(response);

            // Send initialize request to Etch debug server
            setTimeout(() => {
                this.sendToEtch('initialize', {});

                // Send launch request to Etch debug server
                setTimeout(() => {
                    const stopAtEntry = launchArgs.stopAtEntry || false;
                    log(`Sending launch with stopAtEntry: ${stopAtEntry}`);
                    this.sendToEtch('launch', {
                        program: program,
                        stopAtEntry: stopAtEntry
                    });

                    // After launch, mark as initialized and process pending requests
                    this.initialized = true;
                    this.processPendingRequests();
                }, 100);
            }, 500); // Give Etch process time to start

        } catch (error) {
            log(`Failed to spawn Etch process: ${error}`);
            this.sendErrorResponse(response, 2003, `Failed to spawn Etch process: ${error}`);
        }
    }

    protected disconnectRequest(response: DebugProtocol.DisconnectResponse, args: DebugProtocol.DisconnectArguments): void {
        log('Handling disconnect request');

        if (this.etchProcess) {
            log('Terminating Etch process');
            this.etchProcess.kill();
            this.etchProcess = undefined;
        }

        this.sendResponse(response);
    }

    private processPendingRequests(): void {
        log(`Processing ${this.pendingRequests.length} pending requests`);

        const requests = this.pendingRequests;
        this.pendingRequests = [];

        for (const req of requests) {
            this.sendToEtch(req.command, req.args);

            // Send response if provided
            if (req.response) {
                if (req.command === 'setBreakpoints') {
                    req.response.body = {
                        breakpoints: req.args.lines.map((line: number) => ({ verified: true, line: line }))
                    };
                }
                this.sendResponse(req.response);
            }
        }
    }


    private handleEtchMessage(message: any): void {
        if (message.type === 'event') {
            log(`Forwarding event to VSCode: ${message.event}`);

            switch (message.event) {
                case 'stopped':
                    // Update current position if provided
                    if (message.body.file) {
                        this.currentFile = message.body.file;
                    }
                    if (message.body.line) {
                        this.currentLine = message.body.line;
                    }

                    this.sendEvent(new StoppedEvent(
                        message.body.reason || 'pause',
                        message.body.threadId || EtchDebugAdapter.THREAD_ID
                    ));
                    break;

                case 'terminated':
                    this.sendEvent(new TerminatedEvent());
                    break;

                case 'output':
                    // Create an OutputEvent with the message body
                    this.sendEvent(new OutputEvent(message.body.output, message.body.category));
                    break;

                default:
                    // For other events, just log them
                    log(`Unhandled event type: ${message.event}`);
            }
        } else if (message.type === 'response') {
            log(`Received response from Etch: ${JSON.stringify(message)}`);
            this.handleEtchResponse(message);
        }
    }

    private handleEtchResponse(message: any): void {
        if (!message.command) {
            log('Warning: Received response without command field');
            return;
        }

        switch (message.command) {
            case 'stackTrace':
                if (message.request_seq !== undefined) {
                    const response = this.pendingStackTraceResponses.get(message.request_seq);
                    if (response && message.body) {
                        // Convert Etch's stack frames to VS Code format
                        const stackFrames = message.body.stackFrames?.map((frame: any, index: number) => {
                            const source = new Source(frame.source.name, frame.source.path);
                            return new StackFrame(frame.id, frame.name, source, frame.line, frame.column);
                        }) || [];

                        response.body = {
                            stackFrames: stackFrames,
                            totalFrames: message.body.totalFrames || stackFrames.length
                        };

                        log(`Forwarding ${stackFrames.length} stack frames to VS Code`);
                        this.sendResponse(response);
                        this.pendingStackTraceResponses.delete(message.request_seq);
                    }
                }
                break;

            case 'variables':
                if (message.request_seq !== undefined) {
                    const response = this.pendingVariablesResponses.get(message.request_seq);
                    if (response && message.body) {
                        // Forward variables directly
                        response.body = {
                            variables: message.body.variables || []
                        };

                        log(`Forwarding ${message.body.variables?.length || 0} variables to VS Code (seq=${message.request_seq})`);
                        this.sendResponse(response);
                        this.pendingVariablesResponses.delete(message.request_seq);
                    } else if (!response) {
                        log(`ERROR: No pending response found for variables seq=${message.request_seq}, pending keys: ${Array.from(this.pendingVariablesResponses.keys())}`);
                    }
                }
                break;

            case 'scopes':
                if (message.request_seq !== undefined) {
                    const response = this.pendingScopesResponses.get(message.request_seq);
                    if (response && message.body) {
                        // Forward scopes directly
                        response.body = {
                            scopes: message.body.scopes || []
                        };

                        log(`Forwarding ${message.body.scopes?.length || 0} scopes to VS Code`);
                        this.sendResponse(response);
                        this.pendingScopesResponses.delete(message.request_seq);
                    }
                }
                break;

            case 'setVariable':
                const setVarResponse = this.pendingCustomResponses.get('setVariable');
                if (setVarResponse && message.body) {
                    // Forward the updated variable info
                    setVarResponse.body = {
                        value: message.body.value,
                        type: message.body.type,
                        variablesReference: message.body.variablesReference || 0
                    };

                    log(`Variable set successfully: ${message.body.value}`);
                    this.sendResponse(setVarResponse);
                    this.pendingCustomResponses.delete('setVariable');
                } else if (setVarResponse && !message.success) {
                    // Handle error case
                    this.sendErrorResponse(setVarResponse, 3001, message.message || 'Failed to set variable');
                    this.pendingCustomResponses.delete('setVariable');
                }
                break;

            default:
                log(`Unhandled response command: ${message.command}`);
                break;
        }
    }

    private sendToEtch(command: string, args?: any): void {
        if (!this.etchProcess) {
            log(`ERROR: Cannot send ${command} - Etch process not started`);
            return;
        }

        if (!this.etchProcess.stdin) {
            log(`ERROR: Cannot send ${command} - Etch stdin not available`);
            return;
        }

        const request = {
            seq: this.nextSeq++,
            type: 'request',
            command: command,
            arguments: args || {}
        };

        const message = JSON.stringify(request) + '\n';
        log(`Sending to Etch: ${message.trim()}`);
        this.etchProcess.stdin.write(message);
    }

    // Override debug protocol methods to forward to Etch
    protected setBreakPointsRequest(response: DebugProtocol.SetBreakpointsResponse, args: DebugProtocol.SetBreakpointsArguments): void {
        log('Setting breakpoints');

        if (!this.initialized) {
            // Queue request until after initialization
            this.pendingRequests.push({
                command: 'setBreakpoints',
                args: {
                    path: args.source.path,
                    lines: args.breakpoints?.map(bp => bp.line) || []
                },
                response: response
            });
            return;
        }

        this.sendToEtch('setBreakpoints', {
            path: args.source.path,
            lines: args.breakpoints?.map(bp => bp.line) || []
        });

        // Send immediate response for now - in a real implementation we'd wait for Etch's response
        response.body = {
            breakpoints: args.breakpoints?.map(bp => ({ verified: true, line: bp.line })) || []
        };
        this.sendResponse(response);
    }

    protected continueRequest(response: DebugProtocol.ContinueResponse, args: DebugProtocol.ContinueArguments): void {
        log('Continue request');
        this.sendToEtch('continue');
        this.sendResponse(response);
    }

    protected nextRequest(response: DebugProtocol.NextResponse, args: DebugProtocol.NextArguments): void {
        log('Next (step over) request');
        this.sendToEtch('next');
        this.sendResponse(response);
    }

    protected stepInRequest(response: DebugProtocol.StepInResponse, args: DebugProtocol.StepInArguments): void {
        log('Step in request');
        this.sendToEtch('stepIn');
        this.sendResponse(response);
    }

    protected stepOutRequest(response: DebugProtocol.StepOutResponse, args: DebugProtocol.StepOutArguments): void {
        log('Step out request');
        this.sendToEtch('stepOut');
        this.sendResponse(response);
    }

    protected pauseRequest(response: DebugProtocol.PauseResponse, args: DebugProtocol.PauseArguments): void {
        log('Pause request');
        this.sendToEtch('pause');
        this.sendResponse(response);
    }

    protected stackTraceRequest(response: DebugProtocol.StackTraceResponse, args: DebugProtocol.StackTraceArguments): void {
        log(`Stack trace request for thread ${args.threadId}`);

        // Capture sequence number BEFORE sendToEtch (which does post-increment)
        const seq = this.nextSeq;
        this.pendingStackTraceResponses.set(seq, response);
        this.sendToEtch('stackTrace', { threadId: args.threadId });

        log(`Stored stackTrace response with seq=${seq}`);
    }

    protected scopesRequest(response: DebugProtocol.ScopesResponse, args: DebugProtocol.ScopesArguments): void {
        log(`Scopes request for frame ${args.frameId}`);

        // Capture sequence number BEFORE sendToEtch (which does post-increment)
        const seq = this.nextSeq;
        this.pendingScopesResponses.set(seq, response);
        this.sendToEtch('scopes', { frameId: args.frameId });

        log(`Stored scopes response with seq=${seq}`);
    }

    protected variablesRequest(response: DebugProtocol.VariablesResponse, args: DebugProtocol.VariablesArguments): void {
        log(`Variables request for variablesReference ${args.variablesReference}`);

        // Capture sequence number BEFORE sendToEtch (which does post-increment)
        const seq = this.nextSeq;
        this.pendingVariablesResponses.set(seq, response);
        this.sendToEtch('variables', { variablesReference: args.variablesReference });

        log(`Stored variables response with seq=${seq}, ref=${args.variablesReference}`);
    }

    protected threadsRequest(response: DebugProtocol.ThreadsResponse): void {
        log('Threads request');
        response.body = {
            threads: [
                new Thread(EtchDebugAdapter.THREAD_ID, "main")
            ]
        };
        this.sendResponse(response);
    }

    protected configurationDoneRequest(response: DebugProtocol.ConfigurationDoneResponse, args: DebugProtocol.ConfigurationDoneArguments): void {
        log('Configuration done request');
        this.sendToEtch('configurationDone');
        this.sendResponse(response);
    }

    protected setVariableRequest(response: DebugProtocol.SetVariableResponse, args: DebugProtocol.SetVariableArguments): void {
        log(`Set variable request: ${args.name} = ${args.value}`);

        // Store the response to send back when we get Etch's response
        this.pendingCustomResponses.set('setVariable', response);

        // Forward request to Etch debug server
        this.sendToEtch('setVariable', {
            variablesReference: args.variablesReference,
            name: args.name,
            value: args.value
        });
    }

    public shutdown(): void {
        log('Debug adapter shutdown called');
        if (this.etchProcess) {
            this.etchProcess.kill();
            this.etchProcess = undefined;
        }
        super.shutdown();
    }
}

// Remote Debug Adapter - connects to TCP server instead of spawning process
class RemoteEtchDebugAdapter extends DebugSession {
    private static THREAD_ID = 1;
    private socket: net.Socket | undefined;
    private nextSeq = 1;
    private currentFile: string = '';
    private currentLine: number = 0;
    private initialized = false;
    private pendingRequests: Array<{command: string, args: any, response?: any}> = [];

    // Connection state tracking
    private connectionTimer: NodeJS.Timeout | undefined;
    private retryTimer: NodeJS.Timeout | undefined;
    private connecting = false;

    // Pending responses waiting for Etch server replies
    // Use Maps to handle multiple concurrent requests (e.g., Locals and Globals requested simultaneously)
    private pendingStackTraceResponses: Map<number, DebugProtocol.StackTraceResponse> = new Map();
    private pendingVariablesResponses: Map<number, DebugProtocol.VariablesResponse> = new Map();
    private pendingScopesResponses: Map<number, DebugProtocol.ScopesResponse> = new Map();
    private pendingCustomResponses: Map<string, any> = new Map();

    constructor() {
        super();
        log('RemoteEtchDebugAdapter created');
        this.setDebuggerLinesStartAt1(true);
        this.setDebuggerColumnsStartAt1(true);
    }

    protected initializeRequest(response: DebugProtocol.InitializeResponse, args: DebugProtocol.InitializeRequestArguments): void {
        log('Remote: Handling initialize request');

        response.body = response.body || {};
        response.body.supportsConfigurationDoneRequest = true;
        response.body.supportsBreakpointLocationsRequest = false;
        response.body.supportsStepBack = false;
        response.body.supportsRestartFrame = false;
        response.body.supportsTerminateRequest = true;
        response.body.supportsSetVariable = true;

        this.sendResponse(response);
        this.sendEvent(new InitializedEvent());
        log('Remote: Sent initialize response and initialized event');
    }

    protected attachRequest(response: DebugProtocol.AttachResponse, args: DebugProtocol.AttachRequestArguments): void {
        log('Remote: Handling attach request');
        log(`Remote: Attach args: ${JSON.stringify(args, null, 2)}`);

        const attachArgs = args as any;
        const host = attachArgs.host || '127.0.0.1';
        const port = attachArgs.port || 9823;
        const timeout = attachArgs.timeout || 30000;  // 30 second default timeout

        log(`Remote: Connecting to ${host}:${port} (timeout: ${timeout}ms)`);

        // Simple retry loop with clean connection handling
        let connected = false;
        const retryInterval = 500;  // Try every 500ms
        const maxRetries = Math.floor(timeout / retryInterval);
        let retryCount = 0;
        let buffer = '';

        const attemptConnection = () => {
            // Check if we should stop (max retries or explicitly cancelled)
            if (retryCount >= maxRetries) {
                log(`Remote: Max retries (${maxRetries}) exceeded`);
                this.sendErrorResponse(response, 2002,
                    `Failed to connect after ${retryCount} attempts. ` +
                    `Make sure the C++ application is running with ETCH_DEBUG_PORT=${port}`);
                return;
            }

            // Check if cancelled (only if we were connecting)
            if (retryCount > 0 && this.connecting === false) {
                log(`Remote: Connection cancelled after ${retryCount} attempts`);
                this.sendErrorResponse(response, 2002, `Connection cancelled`);
                return;
            }

            retryCount++;
            this.connecting = true;
            log(`Remote: Connection attempt ${retryCount}/${maxRetries}`);

            // Create fresh socket for each attempt
            if (this.socket) {
                this.socket.removeAllListeners();
                try { this.socket.destroy(); } catch (e) { /* ignore */ }
            }

            this.socket = new net.Socket();

            // Success handler
            this.socket.once('connect', () => {
                this.connecting = false;
                connected = true;

                if (this.connectionTimer) {
                    clearTimeout(this.connectionTimer);
                    this.connectionTimer = undefined;
                }

                log(`Remote: Connected to Etch debug server at ${host}:${port}`);
                this.sendResponse(response);

                // Set up data handler for established connection
                this.socket!.on('data', (data) => {
                    const dataStr = data.toString();
                    log(`Remote: Raw data received (${dataStr.length} bytes): ${dataStr.substring(0, 200)}...`);

                    buffer += dataStr;
                    const lines = buffer.split('\n');
                    buffer = lines.pop() || '';

                    log(`Remote: Processing ${lines.length} complete lines`);

                    for (const line of lines) {
                        if (line.trim()) {
                            try {
                                const message = JSON.parse(line.trim());
                                log(`Remote: Received from Etch: ${JSON.stringify(message, null, 2)}`);
                                this.handleEtchMessage(message);
                            } catch (e) {
                                log(`Remote: Failed to parse JSON: ${line.trim()}: ${e}`);
                            }
                        }
                    }
                });

                // Handle disconnection after successful connection
                this.socket!.once('close', () => {
                    log('Remote: Connection closed');
                    if (this.initialized) {
                        this.sendEvent(new TerminatedEvent());
                    }
                });

                // Send initialization sequence
                setTimeout(() => {
                    this.sendToEtch('initialize', {});
                    setTimeout(() => {
                        const stopAtEntry = attachArgs.stopAtEntry || false;
                        log(`Remote: Sending launch with stopAtEntry: ${stopAtEntry}`);
                        this.sendToEtch('launch', {
                            program: attachArgs.program || '<embedded>',
                            stopAtEntry: stopAtEntry
                        });
                        this.initialized = true;
                        this.processPendingRequests();
                    }, 100);
                }, 100);
            });

            // Error handler - retry on ECONNREFUSED
            this.socket.once('error', (error) => {
                if (error.message.includes('ECONNREFUSED')) {
                    log(`Remote: Connection refused (attempt ${retryCount}/${maxRetries}), retrying in ${retryInterval}ms...`);
                    this.retryTimer = setTimeout(attemptConnection, retryInterval);
                } else {
                    // Other error - don't retry
                    log(`Remote: Connection error: ${error.message}`);
                    this.connecting = false;
                    if (!this.initialized) {
                        this.sendErrorResponse(response, 2002, `Failed to connect: ${error.message}`);
                    }
                }
            });

            // Attempt connection
            this.socket.connect(port, host);
        };

        // Start retry loop
        attemptConnection();
    }

    private processPendingRequests(): void {
        log(`Remote: Processing ${this.pendingRequests.length} pending requests`);

        const requests = this.pendingRequests;
        this.pendingRequests = [];

        for (const req of requests) {
            this.sendToEtch(req.command, req.args);

            if (req.response) {
                if (req.command === 'setBreakpoints') {
                    req.response.body = {
                        breakpoints: req.args.lines.map((line: number) => ({ verified: true, line: line }))
                    };
                }
                this.sendResponse(req.response);
            }
        }
    }

    private handleEtchMessage(message: any): void {
        if (message.type === 'event') {
            log(`Remote: Forwarding event to VSCode: ${message.event}`);

            switch (message.event) {
                case 'stopped':
                    if (message.body.file) {
                        this.currentFile = message.body.file;
                    }
                    if (message.body.line) {
                        this.currentLine = message.body.line;
                    }

                    this.sendEvent(new StoppedEvent(
                        message.body.reason || 'pause',
                        message.body.threadId || RemoteEtchDebugAdapter.THREAD_ID
                    ));
                    break;

                case 'terminated':
                    this.sendEvent(new TerminatedEvent());
                    break;

                case 'output':
                    this.sendEvent(new OutputEvent(message.body.output, message.body.category));
                    break;

                default:
                    log(`Remote: Unhandled event type: ${message.event}`);
            }
        } else if (message.type === 'response') {
            log(`Remote: Received response from Etch: ${JSON.stringify(message)}`);
            this.handleEtchResponse(message);
        }
    }

    private handleEtchResponse(message: any): void {
        if (!message.command) {
            log('Remote: Warning: Received response without command field');
            return;
        }

        switch (message.command) {
            case 'stackTrace':
                if (message.request_seq !== undefined) {
                    const response = this.pendingStackTraceResponses.get(message.request_seq);
                    if (response && message.body) {
                        const stackFrames = message.body.stackFrames?.map((frame: any, index: number) => {
                            const source = new Source(frame.source.name, frame.source.path);
                            return new StackFrame(frame.id, frame.name, source, frame.line, frame.column);
                        }) || [];

                        response.body = {
                            stackFrames: stackFrames,
                            totalFrames: message.body.totalFrames || stackFrames.length
                        };

                        log(`Remote: Forwarding ${stackFrames.length} stack frames to VS Code`);
                        this.sendResponse(response);
                        this.pendingStackTraceResponses.delete(message.request_seq);
                    }
                }
                break;

            case 'variables':
                if (message.request_seq !== undefined) {
                    const response = this.pendingVariablesResponses.get(message.request_seq);
                    if (response && message.body) {
                        response.body = {
                            variables: message.body.variables || []
                        };

                        log(`Remote: Forwarding ${message.body.variables?.length || 0} variables to VS Code (seq=${message.request_seq})`);
                        this.sendResponse(response);
                        this.pendingVariablesResponses.delete(message.request_seq);
                    } else if (!response) {
                        log(`Remote: ERROR: No pending response found for variables seq=${message.request_seq}, pending keys: ${Array.from(this.pendingVariablesResponses.keys())}`);
                    }
                }
                break;

            case 'scopes':
                if (message.request_seq !== undefined) {
                    const response = this.pendingScopesResponses.get(message.request_seq);
                    if (response && message.body) {
                        response.body = {
                            scopes: message.body.scopes || []
                        };

                        log(`Remote: Forwarding ${message.body.scopes?.length || 0} scopes to VS Code`);
                        this.sendResponse(response);
                        this.pendingScopesResponses.delete(message.request_seq);
                    }
                }
                break;

            case 'setVariable':
                const setVarResponse = this.pendingCustomResponses.get('setVariable');
                if (setVarResponse && message.body) {
                    setVarResponse.body = {
                        value: message.body.value,
                        type: message.body.type,
                        variablesReference: message.body.variablesReference || 0
                    };

                    log(`Remote: Variable set successfully: ${message.body.value}`);
                    this.sendResponse(setVarResponse);
                    this.pendingCustomResponses.delete('setVariable');
                } else if (setVarResponse && !message.success) {
                    this.sendErrorResponse(setVarResponse, 3001, message.message || 'Failed to set variable');
                    this.pendingCustomResponses.delete('setVariable');
                }
                break;

            default:
                log(`Remote: Unhandled response command: ${message.command}`);
                break;
        }
    }

    private sendToEtch(command: string, args?: any): void {
        if (!this.socket) {
            log(`Remote: ERROR: Cannot send ${command} - socket not connected`);
            return;
        }

        const request = {
            seq: this.nextSeq++,
            type: 'request',
            command: command,
            arguments: args || {}
        };

        const message = JSON.stringify(request) + '\n';
        log(`Remote: Sending to Etch: ${message.trim()}`);
        this.socket.write(message);
    }

    protected disconnectRequest(response: DebugProtocol.DisconnectResponse, args: DebugProtocol.DisconnectArguments): void {
        log('Remote: Handling disconnect request');

        // Cancel any pending connection timers
        if (this.connectionTimer) {
            clearTimeout(this.connectionTimer);
            this.connectionTimer = undefined;
            log('Remote: Cancelled connection timeout timer');
        }

        if (this.retryTimer) {
            clearTimeout(this.retryTimer);
            this.retryTimer = undefined;
            log('Remote: Cancelled retry timer');
        }

        this.connecting = false;

        // Send disconnect if we're connected
        if (this.socket && this.initialized) {
            this.sendToEtch('disconnect');
            setTimeout(() => {
                this.socket?.destroy();
                this.socket = undefined;
                log('Remote: Socket destroyed after disconnect');
            }, 100);
        } else if (this.socket) {
            // Just destroy the socket if we're still connecting
            this.socket.destroy();
            this.socket = undefined;
            log('Remote: Socket destroyed (was still connecting)');
        }

        this.sendResponse(response);
    }

    // Forward all debug protocol methods to Etch server (similar to EtchDebugAdapter)
    protected setBreakPointsRequest(response: DebugProtocol.SetBreakpointsResponse, args: DebugProtocol.SetBreakpointsArguments): void {
        log('Remote: Setting breakpoints');

        if (!this.initialized) {
            this.pendingRequests.push({
                command: 'setBreakpoints',
                args: {
                    path: args.source.path,
                    lines: args.breakpoints?.map(bp => bp.line) || []
                },
                response: response
            });
            return;
        }

        this.sendToEtch('setBreakpoints', {
            path: args.source.path,
            lines: args.breakpoints?.map(bp => bp.line) || []
        });

        response.body = {
            breakpoints: args.breakpoints?.map(bp => ({ verified: true, line: bp.line })) || []
        };
        this.sendResponse(response);
    }

    protected continueRequest(response: DebugProtocol.ContinueResponse, args: DebugProtocol.ContinueArguments): void {
        log('Remote: Continue request');
        this.sendToEtch('continue');
        this.sendResponse(response);
    }

    protected nextRequest(response: DebugProtocol.NextResponse, args: DebugProtocol.NextArguments): void {
        log('Remote: Next (step over) request');
        this.sendToEtch('next');
        this.sendResponse(response);
    }

    protected stepInRequest(response: DebugProtocol.StepInResponse, args: DebugProtocol.StepInArguments): void {
        log('Remote: Step in request');
        this.sendToEtch('stepIn');
        this.sendResponse(response);
    }

    protected stepOutRequest(response: DebugProtocol.StepOutResponse, args: DebugProtocol.StepOutArguments): void {
        log('Remote: Step out request');
        this.sendToEtch('stepOut');
        this.sendResponse(response);
    }

    protected pauseRequest(response: DebugProtocol.PauseResponse, args: DebugProtocol.PauseArguments): void {
        log('Remote: Pause request');
        this.sendToEtch('pause');
        this.sendResponse(response);
    }

    protected stackTraceRequest(response: DebugProtocol.StackTraceResponse, args: DebugProtocol.StackTraceArguments): void {
        log(`Remote: Stack trace request for thread ${args.threadId}`);
        const seq = this.nextSeq;
        this.pendingStackTraceResponses.set(seq, response);
        this.sendToEtch('stackTrace', { threadId: args.threadId });
        log(`Remote: Stored stackTrace response with seq=${seq}`);
    }

    protected scopesRequest(response: DebugProtocol.ScopesResponse, args: DebugProtocol.ScopesArguments): void {
        log(`Remote: Scopes request for frame ${args.frameId}`);
        const seq = this.nextSeq;
        this.pendingScopesResponses.set(seq, response);
        this.sendToEtch('scopes', { frameId: args.frameId });
        log(`Remote: Stored scopes response with seq=${seq}`);
    }

    protected variablesRequest(response: DebugProtocol.VariablesResponse, args: DebugProtocol.VariablesArguments): void {
        log(`Remote: Variables request for variablesReference ${args.variablesReference}`);
        const seq = this.nextSeq;
        this.pendingVariablesResponses.set(seq, response);
        this.sendToEtch('variables', { variablesReference: args.variablesReference });
        log(`Remote: Stored variables response with seq=${seq}, ref=${args.variablesReference}`);
    }

    protected threadsRequest(response: DebugProtocol.ThreadsResponse): void {
        log('Remote: Threads request');
        response.body = {
            threads: [
                new Thread(RemoteEtchDebugAdapter.THREAD_ID, "main")
            ]
        };
        this.sendResponse(response);
    }

    protected configurationDoneRequest(response: DebugProtocol.ConfigurationDoneResponse, args: DebugProtocol.ConfigurationDoneArguments): void {
        log('Remote: Configuration done request');
        this.sendToEtch('configurationDone');
        this.sendResponse(response);
    }

    protected setVariableRequest(response: DebugProtocol.SetVariableResponse, args: DebugProtocol.SetVariableArguments): void {
        log(`Remote: Set variable request: ${args.name} = ${args.value}`);
        this.pendingCustomResponses.set('setVariable', response);
        this.sendToEtch('setVariable', {
            variablesReference: args.variablesReference,
            name: args.name,
            value: args.value
        });
    }

    public shutdown(): void {
        log('Remote: Debug adapter shutdown called');
        if (this.socket) {
            this.socket.destroy();
            this.socket = undefined;
        }
        super.shutdown();
    }
}

