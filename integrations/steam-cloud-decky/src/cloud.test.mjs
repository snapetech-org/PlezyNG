import test from 'node:test';
import assert from 'node:assert/strict';
import {createCloudController, decodeCloud} from './cloud.mjs';
const account = '76561198000000001';
const bytes = b => Uint8Array.from([0x80,0xf1,0x04,b ? 1 : 0]).buffer;
function fixture() {
  let user, setting, login, writes = [];
  const steam = {User: {
    RegisterForCurrentUserChanges(fn) { user = fn; },
    RegisterForLoginStateChange(fn) { login = fn; return {unregister(){}}; },
  }, Settings: {
    RegisterForSettingsArrayChanges(fn) { setting = fn; return {unregister(){}}; },
    async SetSetting(b) { writes.push(b); setting(bytes(b === 'gPEEAQ==')); return true; },
  }};
  const controller = createCloudController(steam, 20);
  user({strSteamID:account,bIsOfflineMode:false}); setting(bytes(true));
  return {controller, steam, writes, user: v=>user(v), setting: v=>setting(v), login: v=>login('',v)};
}
const read = {op:'read',steamId:account};
const disable = {op:'set',steamId:account,expected:true,enabled:false};
test('exact field, missing value, duplicate, malformed and overlong settings', () => {
  assert.equal(decodeCloud(bytes(false)),false);
  assert.equal(decodeCloud(new ArrayBuffer(0)),undefined);
  assert.throws(()=>decodeCloud(Uint8Array.from([0x80,0xf1,4,1,0x80,0xf1,4,0]).buffer));
  assert.throws(()=>decodeCloud(Uint8Array.from([0x80,0xf1,4,2]).buffer));
  assert.throws(()=>decodeCloud(Uint8Array.from([0x12,99]).buffer));
  assert.throws(()=>decodeCloud(new ArrayBuffer(65537)));
});
test('observed write uses only field10000 and requires readback plus acceptance',async()=>{
  const f=fixture();
  assert.equal((await f.controller.execute(disable,async()=>true,()=>true)).status,'observed');
  assert.deepEqual(f.writes,['gPEEAA==']); f.controller.dispose();
});
test('acceptance without readback is unknown',async()=>{
  const f=fixture(); f.steam.Settings.SetSetting=async()=>true;
  assert.equal((await f.controller.execute(disable,async()=>true,()=>true)).status,'unknown'); f.controller.dispose();
});
test('denial, stale review and lost claim cannot write',async()=>{
  const f=fixture();
  assert.equal((await f.controller.execute(disable,async()=>true,()=>false)).status,'unavailable');
  assert.equal((await f.controller.execute({...disable,expected:false},async()=>true,()=>true)).status,'stale');
  assert.equal((await f.controller.execute(disable,async()=>false,()=>true)).status,'unavailable');
  assert.deepEqual(f.writes,[]); f.controller.dispose();
});
test('account changes during claim cannot mutate a different account',async()=>{
  const f=fixture();
  const result=await f.controller.execute(disable,async()=>{f.user({strSteamID:'76561198000000002'});f.setting(bytes(true));return true;},()=>true);
  assert.equal(result.status,'unavailable'); assert.deepEqual(f.writes,[]); f.controller.dispose();
});
test('logout and missing cloud fields retire observed state',async()=>{
  const f=fixture(); f.setting(new ArrayBuffer(0));
  assert.equal((await f.controller.execute(read,async()=>true,()=>true)).status,'unavailable');
  f.setting(bytes(true)); f.login(1);
  assert.equal((await f.controller.execute(read,async()=>true,()=>true)).status,'unavailable'); f.controller.dispose();
});
test('callback from retired account and disposed controller is ignored',async()=>{
  const f=fixture();const old=f.setting; f.controller.dispose(); old(bytes(false));
  assert.equal((await f.controller.execute(read,async()=>true,()=>true)).status,'unavailable');
});
