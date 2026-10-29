#include <assert.h>
#include <limits.h>
#include <string.h>

#include "ihs_buffer.h"
#include "ihs_buffer_ext.h"
#include "ihslib.h"
#include "session/channels/ch_control.h"
#include "test_session.h"

struct IHS_QueueItem {
  IHS_SessionPacket packet;
  bool reliable;
};
static void configure(IHS_Session* session, IHS_SessionConfig* config, void* context) {
  (void)session;
  const unsigned flags = *(unsigned*)context;
  config->enablePyrowave = (flags & 1) != 0;
  config->enableHdr10 = (flags & 2) != 0;
}
static void wire_colorspaces(unsigned flags, EStreamVideoCodec video, bool hdr) {
  IHS_Session* s = IHS_TestSessionCreate();
  IHS_TimerTaskStopImmediate(s->retransmission.timer);
  IHS_TimerTaskStopImmediate(((IHS_SessionChannelControl*)s->channels[1])->feedbackTimer);
  const IHS_StreamSessionCallbacks callbacks = {.configuring = configure};
  IHS_SessionSetSessionCallbacks(s, &callbacks, &flags);
  s->state.connectionState = IHS_SessionConnectionStateNegotiating;
  CNegotiationInitMsg message = CNEGOTIATION_INIT_MSG__INIT;
  message.n_supported_video_codecs = 1;
  message.supported_video_codecs = &video;
  IHS_Buffer body = IHS_BUFFER_INIT(1024, 1024);
  IHS_BufferAppendMessage(&body, (ProtobufCMessage*)&message);
  IHS_SessionPacketHeader header = {0};
  IHS_SessionChannelControlOnNegotiation(s->channels[1], k_EStreamControlNegotiationInit, &body, &header);
  IHS_QueueItem* q = IHS_QueuePoll(s->sendQueue);
  assert(q && q->packet.header.fragmentId == 0);
  assert(*IHS_BufferPointer(&q->packet.body) == k_EStreamControlNegotiationSetConfig);
  IHS_BufferOffsetBy(&q->packet.body, 1);
  IHS_Buffer plain = IHS_BUFFER_INIT(2048, 2048);
  uint64_t sequence;
  assert(IHS_SessionFrameDecrypt(s, &q->packet.body, &plain, 0, &sequence) == 0);
  CNegotiationSetConfigMsg* config = cnegotiation_set_config_msg__unpack(NULL, plain.size, IHS_BufferPointer(&plain));
  assert(config && config->streaming_client_caps);
  CStreamingClientCaps* caps = config->streaming_client_caps;
  assert(caps->n_supported_colorspaces == (hdr ? 3 : 2));
  assert(caps->supported_colorspaces[0] == k_EStreamColorspace_BT709);
  assert(caps->supported_colorspaces[1] == k_EStreamColorspace_BT709_Full);
  if (hdr) assert(caps->supported_colorspaces[2] == k_EStreamColorspace_HDR10);
  cnegotiation_set_config_msg__free_unpacked(config, NULL);
  IHS_BufferClear(&plain, true);
  IHS_BufferClear(&body, true);
  IHS_SessionPacketClear(&q->packet, true);
  IHS_QueueItemFree(q);
  IHS_SessionDestroy(s);
}
int main(void) {
  IHS_Init();
  wire_colorspaces(0, k_EStreamVideoCodecH264, false);
  wire_colorspaces(2, k_EStreamVideoCodecH264, false);
  wire_colorspaces(3, k_EStreamVideoCodecH264, false);
  wire_colorspaces(1, k_EStreamVideoCodecPyrowave, false);
  wire_colorspaces(3, k_EStreamVideoCodecPyrowave, true);
  IHS_Quit();
}
