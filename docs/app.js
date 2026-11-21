// Subscribes this installed web app to Web Push and shows the subscription
// JSON, which the Mac sends to with ./push.sh. Text only, no HTML insertion.
const $ = (id) => document.getElementById(id);

const standalone =
  window.matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;
const supported =
  'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;

function fromBase64Url(text) {
  const padded = text.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (text.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

function showStatus() {
  $('installed').textContent = standalone
    ? 'yes'
    : 'no: Share → Add to Home Screen, then open it from there';
  $('supported').textContent = supported ? 'yes' : 'no';
  $('permission').textContent = 'Notification' in window ? Notification.permission : 'n/a';
  $('enable').disabled = !supported;
}

function showSubscription(subscription) {
  $('subscription').value = subscription ? JSON.stringify(subscription, null, 2) : '';
  $('copy').disabled = !subscription;
}

function showError(error) {
  $('error').textContent = String(error);
}

async function start() {
  showStatus();
  if (!supported) return;
  const registration = await navigator.serviceWorker.register('sw.js');
  showSubscription(await registration.pushManager.getSubscription());
}

$('enable').addEventListener('click', async () => {
  try {
    // Must be the first thing the tap does: Safari asks only from a tap.
    const permission = await Notification.requestPermission();
    showStatus();
    if (permission !== 'granted') return;
    const registration = await navigator.serviceWorker.ready;
    // Replace an old subscription, e.g. one made with an earlier key.
    const old = await registration.pushManager.getSubscription();
    if (old) await old.unsubscribe();
    const subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: fromBase64Url(VAPID_PUBLIC_KEY),
    });
    showSubscription(subscription);
  } catch (error) {
    showError(error);
  }
});

$('copy').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText($('subscription').value);
    $('copy').textContent = 'Copied';
  } catch (error) {
    showError(error);
  }
});

start().catch(showError);
