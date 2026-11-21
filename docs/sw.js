// Service worker: shows every push as a notification (Safari requires that
// each push shows one) and opens the app when it's tapped.
self.addEventListener('push', (event) => {
  const body = event.data ? event.data.text() : '(empty push)';
  event.waitUntil(self.registration.showNotification('Web Push check', { body }));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: 'window' }).then((windows) =>
      windows.length ? windows[0].focus() : self.clients.openWindow('./'),
    ),
  );
});
