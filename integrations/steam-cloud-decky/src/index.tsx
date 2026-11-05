import {definePlugin, callable, addEventListener, removeEventListener} from '@decky/api';
import {PanelSection, PanelSectionRow, ToggleField} from '@decky/ui';
import {useSyncExternalStore} from 'react';
import {createCloudController} from './cloud.mjs';

declare const SteamClient: any;
const begin = callable<[], string>('begin');
const setEnabled = callable<[boolean, number, string], boolean>('set_enabled');
const claim = callable<[string, string], boolean>('claim');
const complete = callable<[string, object, string], void>('complete');

export default definePlugin(() => {
  let enabled = false, revision = 0;
  const session = begin().catch(() => '');
  const subscribers = new Set<() => void>();
  const publish = (value: boolean) => { enabled = value; for (const fn of subscribers) fn(); };
  const controller = createCloudController(typeof SteamClient === 'undefined' ? undefined : SteamClient);
  function Content() {
    const allowed = useSyncExternalStore(fn => { subscribers.add(fn); return () => { subscribers.delete(fn); }; }, () => enabled);
    return <PanelSection title="PlezyNG Steam Cloud">
      <PanelSectionRow><ToggleField label="Allow Cloud settings changes"
        description="Let this computer's PlezyNG Companion change the signed-in account's Steam Cloud setting. Also requires PlezyNG host-action permission. Resets when this plugin reloads."
        disabled={!controller.supported} checked={allowed} onChange={async next => {
          const intent = ++revision;
          publish(false);
          try {
            const result = await setEnabled(next, intent, await session);
            if (intent === revision) { publish(result); }
          } catch { /* remains off */ }
        }}/></PanelSectionRow>
    </PanelSection>;
  }
  const listener = addEventListener<[string, any]>('cloud_request', async (id, request) => {
    let result = {status: 'unavailable'};
    try { result = await controller.execute(request, async () => claim(id, await session), () => enabled); }
    catch { result = {status: 'unknown'}; }
    await complete(id, result, await session).catch(() => {});
  });
  return {name: 'PlezyNG Steam Cloud', titleView: <span>PlezyNG Steam Cloud</span>,
    content: <Content/>, icon: <span aria-hidden="true">☁</span>,
    onDismount() { publish(false); controller.dispose(); removeEventListener('cloud_request', listener); void session.then(token => setEnabled(false, ++revision, token)).catch(() => {}); }};
});
