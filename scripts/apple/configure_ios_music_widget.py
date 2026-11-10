"""Embed a provisioned WidgetKit target in an isolated iOS archive project."""

import hashlib
from pathlib import PurePosixPath
import plistlib
import zipfile

TARGET = 'MusicWidgetExtension'
BUNDLE = 'org.snapetech.pleazyng.MusicWidgetExtension'
PROFILE_KEY = 'IOS_MUSIC_WIDGET_PROVISIONING_PROFILE_BASE64'


def add_music_widget_target(project: dict) -> None:
    objects = project['objects']
    root_id = project['rootObject']
    root = objects[root_id]
    hosts = [objects[key] for key in root['targets'] if objects[key].get('name') == 'Runner']
    if len(hosts) != 1 or any(objects[key].get('name') == TARGET for key in root['targets']):
        raise ValueError('Expected Runner without a pre-existing music widget target')
    host = hosts[0]

    def add(label, kind, **fields):
        identifier = hashlib.sha256(f'pleazyng-ios-widget:{label}'.encode()).hexdigest()[:24].upper()
        if identifier in objects:
            raise ValueError(f'Unexpected music widget project object collision: {label}')
        objects[identifier] = {'isa': kind, **fields}
        return identifier

    def source(path, file_type):
        return add(path, 'PBXFileReference', path=path, sourceTree='SOURCE_ROOT', lastKnownFileType=file_type)

    shared_sources = []
    for path in ('MusicWidget/MusicWidgetSnapshot.swift', 'MusicWidget/MusicWidgetTransportIntent.swift'):
        references = [key for key, value in objects.items()
                      if value.get('isa') == 'PBXFileReference' and value.get('path') == path]
        if len(references) != 1:
            raise ValueError(f'Expected exactly one shared widget source: {path}')
        shared_sources.append(references[0])
    view = source('MusicWidget/PleazyngMusicWidget.swift', 'sourcecode.swift')
    config = source('Flutter/MusicWidget.xcconfig', 'text.xcconfig')
    group = add('group', 'PBXGroup', name=TARGET, sourceTree='<group>', children=[view, config])
    objects[root['mainGroup']]['children'].append(group)
    product = add('product', 'PBXFileReference', explicitFileType='wrapper.app-extension',
                  includeInIndex='0', path=f'{TARGET}.appex', sourceTree='BUILT_PRODUCTS_DIR')
    objects[root['productRefGroup']]['children'].append(product)

    def phase(label, kind, files, **fields):
        return add(label, kind, buildActionMask='2147483647', files=files,
                   runOnlyForDeploymentPostprocessing='0', **fields)

    sources = phase('sources', 'PBXSourcesBuildPhase', [
        add(f'compile-{reference}', 'PBXBuildFile', fileRef=reference) for reference in [*shared_sources, view]
    ])
    frameworks = phase('frameworks', 'PBXFrameworksBuildPhase', [])
    configs = []
    for host_config_id in objects[host['buildConfigurationList']]['buildConfigurations']:
        host_config = objects[host_config_id]
        name = host_config['name']
        configs.append(add(f'config-{name}', 'XCBuildConfiguration', name=name, baseConfigurationReference=config,
                           buildSettings={
                               'APPLICATION_EXTENSION_API_ONLY': 'YES',
                               'CODE_SIGN_ENTITLEMENTS': 'MusicWidget/MusicWidget.entitlements',
                               'CURRENT_PROJECT_VERSION': '$(FLUTTER_BUILD_NUMBER)',
                               'INFOPLIST_FILE': 'MusicWidget/Info.plist',
                               'IPHONEOS_DEPLOYMENT_TARGET': host_config['buildSettings'].get('IPHONEOS_DEPLOYMENT_TARGET', '15.5'),
                               'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks',
                                                           '@executable_path/../../Frameworks'],
                               'MARKETING_VERSION': '$(FLUTTER_BUILD_NAME)',
                               'OTHER_LDFLAGS': ['$(inherited)', '-weak_framework', 'AppIntents'],
                               'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE,
                               'PRODUCT_NAME': TARGET,
                               'SDKROOT': 'iphoneos',
                               'SKIP_INSTALL': 'YES',
                               'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator',
                               'SWIFT_ACTIVE_COMPILATION_CONDITIONS': '$(inherited) PLEAZYNG_MUSIC_WIDGET_EXTENSION',
                               'SWIFT_VERSION': '5.0',
                               'TARGETED_DEVICE_FAMILY': '1,2',
                           }))
    config_list = add('configs', 'XCConfigurationList', buildConfigurations=configs,
                      defaultConfigurationIsVisible='0', defaultConfigurationName='Release')
    target = add('target', 'PBXNativeTarget', name=TARGET, productName=TARGET, productReference=product,
                 productType='com.apple.product-type.app-extension', buildConfigurationList=config_list,
                 buildPhases=[sources, frameworks], buildRules=[], dependencies=[])
    root['targets'].append(target)
    proxy = add('proxy', 'PBXContainerItemProxy', containerPortal=root_id, proxyType='1',
                remoteGlobalIDString=target, remoteInfo=TARGET)
    host.setdefault('dependencies', []).append(add('dependency', 'PBXTargetDependency', target=target, targetProxy=proxy))
    embedded = add('embedded-product', 'PBXBuildFile', fileRef=product,
                   settings={'ATTRIBUTES': ['CodeSignOnCopy', 'RemoveHeadersOnCopy']})
    embed = phase('embed', 'PBXCopyFilesBuildPhase', [embedded], name='Embed Music Widget', dstPath='', dstSubfolderSpec='13')
    host_phases = host['buildPhases']
    position = next((index for index, key in enumerate(host_phases) if objects[key].get('name') in (
        'Thin Binary', '[CP] Embed Pods Frameworks', '[CP] Copy Pods Resources',
    )), len(host_phases))
    host_phases.insert(position, embed)


def verify_music_widget(ipa) -> None:
    with zipfile.ZipFile(ipa) as package:
        paths = [path for path in package.namelist() if (
            len(parts := PurePosixPath(path).parts) == 5 and parts[0] == 'Payload' and parts[1].endswith('.app')
            and parts[2:] == ('PlugIns', f'{TARGET}.appex', 'Info.plist')
        )]
        if len(paths) != 1 or plistlib.loads(package.read(paths[0])).get('CFBundleIdentifier') != BUNDLE:
            raise ValueError('Exported IPA is missing the expected music widget extension')
