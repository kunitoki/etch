import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';
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

        // Return an inline debug adapter - VS Code will create the debug session in-process
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
    private pendingStackTraceResponse: DebugProtocol.StackTraceResponse | undefined;
    private pendingVariablesResponse: DebugProtocol.VariablesResponse | undefined;
    private pendingScopesResponse: DebugProtocol.ScopesResponse | undefined;
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
            executablePath = path.join(workspacePath, 'etch');
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
                    const stopOnEntry = launchArgs.stopOnEntry || false;
                    log(`Sending launch with stopOnEntry: ${stopOnEntry}`);
                    this.sendToEtch('launch', {
                        program: program,
                        stopOnEntry: stopOnEntry
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
                if (this.pendingStackTraceResponse && message.body) {
                    // Convert Etch's stack frames to VS Code format
                    const stackFrames = message.body.stackFrames?.map((frame: any, index: number) => {
                        const source = new Source(frame.source.name, frame.source.path);
                        return new StackFrame(frame.id, frame.name, source, frame.line, frame.column);
                    }) || [];

                    this.pendingStackTraceResponse.body = {
                        stackFrames: stackFrames,
                        totalFrames: message.body.totalFrames || stackFrames.length
                    };

                    log(`Forwarding ${stackFrames.length} stack frames to VS Code`);
                    this.sendResponse(this.pendingStackTraceResponse);
                    this.pendingStackTraceResponse = undefined;
                }
                break;

            case 'variables':
                if (this.pendingVariablesResponse && message.body) {
                    // Forward variables directly
                    this.pendingVariablesResponse.body = {
                        variables: message.body.variables || []
                    };

                    log(`Forwarding ${message.body.variables?.length || 0} variables to VS Code`);
                    this.sendResponse(this.pendingVariablesResponse);
                    this.pendingVariablesResponse = undefined;
                }
                break;

            case 'scopes':
                if (this.pendingScopesResponse && message.body) {
                    // Forward scopes directly
                    this.pendingScopesResponse.body = {
                        scopes: message.body.scopes || []
                    };

                    log(`Forwarding ${message.body.scopes?.length || 0} scopes to VS Code`);
                    this.sendResponse(this.pendingScopesResponse);
                    this.pendingScopesResponse = undefined;
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

        // Store the response to send back when we get Etch's response
        this.pendingStackTraceResponse = response;

        // Forward request to Etch debug server
        this.sendToEtch('stackTrace', { threadId: args.threadId });
    }

    protected scopesRequest(response: DebugProtocol.ScopesResponse, args: DebugProtocol.ScopesArguments): void {
        log(`Scopes request for frame ${args.frameId}`);

        // Store the response to send back when we get Etch's response
        this.pendingScopesResponse = response;

        // Forward request to Etch debug server
        this.sendToEtch('scopes', { frameId: args.frameId });
    }

    protected variablesRequest(response: DebugProtocol.VariablesResponse, args: DebugProtocol.VariablesArguments): void {
        log(`Variables request for variablesReference ${args.variablesReference}`);

        // Store the response to send back when we get Etch's response
        this.pendingVariablesResponse = response;

        // Forward request to Etch debug server
        this.sendToEtch('variables', { variablesReference: args.variablesReference });
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

