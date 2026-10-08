(() => {
  const contactId = location.pathname.split('/').filter(Boolean).pop();
  const wantsVideo = new URLSearchParams(location.search).get('video') !== '0';
  const title = document.getElementById('title');
  const status = document.getElementById('status');
  const remote = document.getElementById('remote');
  const local = document.getElementById('local');
  const hangup = document.getElementById('hangup');

  const wsProto = location.protocol === 'https:' ? 'wss' : 'ws';
  const ws = new WebSocket(`${wsProto}://${location.host}/ws/${contactId}`);

  let pc;
  let localStream;

  function endCall() {
    status.textContent = 'Call ended';
    try { ws.send(JSON.stringify({ type: 'hangup' })); } catch (_) {}
    if (pc) pc.close();
    if (localStream) localStream.getTracks().forEach((t) => t.stop());
    ws.close();
  }

  hangup.addEventListener('click', endCall);
  window.addEventListener('pagehide', endCall);

  ws.onmessage = async (event) => {
    const msg = JSON.parse(event.data);
    if (msg.type === 'welcome') {
      title.textContent = msg.contact.display_name;
      status.textContent = `${msg.contact.e164} · ${msg.contact.id}`;
      pc = new RTCPeerConnection({
        iceServers: msg.iceServers && msg.iceServers.length
          ? msg.iceServers
          : [{ urls: 'stun:stun.l.google.com:19302' }],
      });
      pc.ontrack = (ev) => {
        if (remote.srcObject !== ev.streams[0]) remote.srcObject = ev.streams[0];
      };
      localStream = await navigator.mediaDevices.getUserMedia({
        audio: true,
        video: wantsVideo || msg.contact.wants_video,
      });
      local.srcObject = localStream;
      localStream.getTracks().forEach((track) => pc.addTrack(track, localStream));
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      ws.send(JSON.stringify({ type: 'offer', sdp: offer.sdp, sdpType: offer.type }));
    } else if (msg.type === 'answer' && pc) {
      await pc.setRemoteDescription({ type: msg.sdpType || 'answer', sdp: msg.sdp });
      status.textContent = 'Connected';
    } else if (msg.type === 'error') {
      status.textContent = msg.error;
    } else if (msg.type === 'ended') {
      endCall();
    }
  };

  ws.onerror = () => { status.textContent = 'Signaling error'; };
  ws.onclose = () => { status.textContent = 'Disconnected'; };
})();
