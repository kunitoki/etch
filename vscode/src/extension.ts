import * as vscode from 'vscode';
import { EtchDebugAdapterProvider } from './debugAdapter';

const outputChannel = vscode.window.createOutputChannel('Etch Language Server');

function log(message: string) {
    const timestamp = new Date().toISOString();
    const logMessage = `[${timestamp}] ${message}`;
    outputChannel.appendLine(logMessage);
    console.log(`[Etch Extension] ${logMessage}`);
}

export function activate(context: vscode.ExtensionContext) {
    log('Extension activation started');

    // Register inline debug adapter
    log('Registering inline debug adapter for type "etch"');
    const debugProvider = new EtchDebugAdapterProvider();
    context.subscriptions.push(
        vscode.debug.registerDebugAdapterDescriptorFactory('etch', debugProvider)
    );

    // Register configuration provider for launch.json
    log('Creating EtchConfigurationProvider');
    const configProvider = new EtchConfigurationProvider();

    log('Registering debug configuration provider for type "etch"');
    context.subscriptions.push(
        vscode.debug.registerDebugConfigurationProvider('etch', configProvider)
    );

    // Listen for debug session events
    context.subscriptions.push(
        vscode.debug.onDidStartDebugSession((session) => {
            log(`Debug session started: ${session.id} (type: ${session.type}, name: ${session.name})`);
            log(`Debug session configuration: ${JSON.stringify(session.configuration, null, 2)}`);
        })
    );

    context.subscriptions.push(
        vscode.debug.onDidTerminateDebugSession((session) => {
            log(`Debug session terminated: ${session.id} (type: ${session.type}, name: ${session.name})`);
        })
    );

    context.subscriptions.push(
        vscode.debug.onDidReceiveDebugSessionCustomEvent((event) => {
            log(`Debug session custom event: ${event.event} from session ${event.session.id}`);
            log(`Event body: ${JSON.stringify(event.body, null, 2)}`);
        })
    );

    log('Extension activation completed successfully');
}

export function deactivate() {
    log('Extension deactivation started');
    outputChannel.dispose();
    log('Extension deactivation completed');
}

class EtchConfigurationProvider implements vscode.DebugConfigurationProvider {

    resolveDebugConfiguration(
        folder: vscode.WorkspaceFolder | undefined,
        config: vscode.DebugConfiguration,
        _token?: vscode.CancellationToken
    ): vscode.ProviderResult<vscode.DebugConfiguration> {
        log('resolveDebugConfiguration called');
        log(`Folder: ${folder ? folder.uri.fsPath : 'undefined'}`);
        log(`Config type: ${config.type}, request: ${config.request}, name: ${config.name}`);
        log(`Initial config: ${JSON.stringify(config, null, 2)}`);

        // if launch.json is missing or empty
        if (!config.type && !config.request && !config.name) {
            log('No debug configuration found, attempting to create default configuration');
            const editor = vscode.window.activeTextEditor;
            if (editor && editor.document.languageId === 'etchlang') {
                log(`Active editor found with Etch language, creating default config for file: ${editor.document.fileName}`);
                config.type = 'etch';
                config.name = 'Launch';
                config.request = 'launch';
                config.program = '${file}';
                config.stopAtEntry = true;
            } else {
                log(`No suitable active editor found. Editor: ${editor ? 'present' : 'none'}, Language: ${editor ? editor.document.languageId : 'N/A'}`);
            }
        }

        // Check request type explicitly
        log(`Checking request type: '${config.request}' (type: ${typeof config.request})`);

        // For attach requests, we don't need a program
        if (config.request === 'attach') {
            log('✓ Attach request detected - skipping program validation');
            // Set defaults for remote debugging
            if (!config.host) {
                config.host = '127.0.0.1';
                log('Set default host: 127.0.0.1');
            }
            if (!config.port) {
                config.port = 9823;
                log('Set default port: 9823');
            }
            log(`✓ Attach config validated: host=${config.host}, port=${config.port}`);
            return config;
        }

        // For launch requests, we need a program
        log('Not an attach request, checking for program field');
        if (!config.program) {
            log('ERROR: No program specified for launch request');
            return vscode.window.showInformationMessage("Cannot find a program to debug").then(_ => {
                log('User acknowledged missing program error, aborting launch');
                return undefined;	// abort launch
            });
        }

        log(`✓ Launch config validated: program=${config.program}`);
        log(`Final resolved config: ${JSON.stringify(config, null, 2)}`);
        return config;
    }
}
