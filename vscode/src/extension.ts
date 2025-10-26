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
                config.stopOnEntry = true;
            } else {
                log(`No suitable active editor found. Editor: ${editor ? 'present' : 'none'}, Language: ${editor ? editor.document.languageId : 'N/A'}`);
            }
        }

        if (!config.program) {
            log('No program specified in configuration, showing error message');
            return vscode.window.showInformationMessage("Cannot find a program to debug").then(_ => {
                log('User acknowledged missing program error, aborting launch');
                return undefined;	// abort launch
            });
        }

        log(`Final resolved config: ${JSON.stringify(config, null, 2)}`);
        return config;
    }
}
