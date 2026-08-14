// GENERATED CODE - DO NOT MODIFY BY HAND.
// Source: packages/protocol/schema/envelope.json

const protocolVersion = 1;

const protocolMessageTypes = <String>{
  'command',
  'event',
  'presence',
  'ack',
  'hello',
  'challenge',
};

const protocolEnvelopeRequiredFields = <String>{
  'protocol_version',
  'message_type',
  'message_id',
  'trace_id',
  'payload_version',
  'payload',
};
