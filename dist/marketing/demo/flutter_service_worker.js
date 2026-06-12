'use strict';
const MANIFEST = 'flutter-app-manifest';
const TEMP = 'flutter-temp-cache';
const CACHE_NAME = 'flutter-app-cache';

const RESOURCES = {"flutter_bootstrap.js": "754e83f80fd0b1fb683fcfdeccdafee2",
"version.json": "f536eb9b082141987448a3a1a3d43bd8",
"index.html": "48208c115302cc81a99d8a3d6735949f",
"/": "48208c115302cc81a99d8a3d6735949f",
"main.dart.js": "e977aadaffbca1d6ff19a2e5c5277fcd",
"flutter.js": "888483df48293866f9f41d3d9274a779",
"favicon.png": "5dcef449791fa27946b3d35ad8803796",
"icons/Icon-192.png": "ac9a721a12bbc803b44f645561ecb1e1",
"icons/Icon-maskable-192.png": "c457ef57daa1d16f64b27b786ec2ea3c",
"icons/Icon-maskable-512.png": "301a7604d45b3e739efc881eb04896ea",
"icons/Icon-512.png": "96e752610906ba2a93c65f8abe1645f1",
"manifest.json": "80d93136048f2c3c813b636a6ca8bcf8",
"assets/AssetManifest.json": "41a916c9f08250fe44d70903c24c0622",
"assets/NOTICES": "9bd109319e2b6d310807613674e40715",
"assets/FontManifest.json": "dc3d03800ccca4601324923c0b1d6d57",
"assets/AssetManifest.bin.json": "10c949a4526e7b2c16d478b2800b82ef",
"assets/packages/cupertino_icons/assets/CupertinoIcons.ttf": "b93248a553f9e8bc17f1065929d5934b",
"assets/shaders/ink_sparkle.frag": "ecc85a2e95f5e9f53123dcaf8cb9b6ce",
"assets/AssetManifest.bin": "2a2a7bb241e076e46cbcd73924410add",
"assets/fonts/MaterialIcons-Regular.otf": "e7069dfd19b331be16bed984668fe080",
"assets/assets/demo/alex_profile.json": "6adee5b43f9206c79631b365dc1dd040",
"assets/assets/demo/locations.json": "1a4265e3dcdd2357d6a73233e0ad75a4",
"assets/assets/demo/dave_sessions.json": "67015f3c795701b888aee3493af0e32b",
"assets/assets/demo/dave_me_expenses.json": "502f15741f420572c82cbb723144bd35",
"assets/assets/demo/alex_progress.json": "97be6269a38f5bf2c452d73db6a0a706",
"assets/assets/demo/expense_categories.json": "ded15e85c292db4b070ca5609306a203",
"assets/assets/demo/expenses_review_pending.json": "a52829fa7c1573348e70729682e6c791",
"assets/assets/demo/schools.json": "0d764a5aacc6bab1cafe4f601010dbd7",
"assets/assets/demo/instructor_pay_outstanding.json": "24e9f813a25d9f50ebcbfee6a11074e0",
"assets/assets/demo/alex_notifications.json": "d1566da1c06b04ad4196fe851a59d6a1",
"assets/assets/demo/travel_times.json": "80c28203ec69b8c84954362f67053557",
"assets/assets/demo/bikes.json": "2825be7f6108d7d5ce28a36a2ef25875",
"assets/assets/demo/bike_expenses/bike_a1_manual_2.json": "0f1fe95130242c8e5dffcaffddf2fe42",
"assets/assets/demo/bike_expenses/bike_a2_manual_3.json": "b19fa831bd382d83d268aa10a0f88807",
"assets/assets/demo/bike_expenses/bike_a2_manual_2.json": "b19fa831bd382d83d268aa10a0f88807",
"assets/assets/demo/bike_expenses/bike_a_manual_1.json": "2f186d55c4bb985c24507a8135cff1ea",
"assets/assets/demo/bike_expenses/bike_a2_manual_1.json": "9b49147c786e47063aa242e16aed6a4e",
"assets/assets/demo/bike_expenses/bike_a1_auto_1.json": "b19fa831bd382d83d268aa10a0f88807",
"assets/assets/demo/bike_expenses/bike_a1_manual_1.json": "4e560621020cb014ec7e00c952d3af7a",
"assets/assets/demo/expenses_review_approved.json": "8b61e67163f6365931100b45342cc991",
"assets/assets/demo/owen_me.json": "6be3da1be575b92ff4086e0c4f446950",
"assets/assets/demo/disruptions.json": "da74d5edfadf8f22f222affffd2f6706",
"assets/assets/demo/dave_time_off.json": "0435b653739ed189591ea8ee46638f71",
"assets/assets/demo/alex_ledger.json": "0afce8505a113811715949251351b4a0",
"assets/assets/demo/dave_me.json": "e0d2e2db7904718e3b2ec3cb0c4c71a7",
"assets/assets/demo/alex_bookings.json": "a983715734839b20cfbd5dbf1b114080",
"assets/assets/demo/calendar.json": "31c26a454e70f9194e0b7b559aa1999d",
"assets/assets/demo/logistics.json": "25716559e67a6250bad9fe971effe06d",
"assets/assets/demo/expenses_review_reimbursed.json": "ccc2f0e3c0bbd3b8a9c3651bcf878baa",
"assets/assets/demo/instructors.json": "e477ee51e4878eb0625cba3e142cfb06",
"assets/assets/demo/alex_sessions.json": "67015f3c795701b888aee3493af0e32b",
"assets/assets/demo/dave_availability.json": "e16cf3966f90262164b7ee35274eb18b",
"assets/assets/demo/school.json": "60299317e49b781b529a7dbb06d3a531",
"assets/assets/demo/course_types.json": "66e65eef37904dcda8e873b99655890b",
"assets/assets/demo/signups_pending.json": "9564d897c66e8c86cfe0b650a25a3e01",
"assets/assets/demo/alex_me.json": "0cf93c15fb5948e3b48f5cfae1126448",
"assets/assets/demo/students.json": "37ac5b5c376a504f45446d57d1922caf",
"canvaskit/skwasm.js": "1ef3ea3a0fec4569e5d531da25f34095",
"canvaskit/skwasm_heavy.js": "413f5b2b2d9345f37de148e2544f584f",
"canvaskit/skwasm.js.symbols": "0088242d10d7e7d6d2649d1fe1bda7c1",
"canvaskit/canvaskit.js.symbols": "58832fbed59e00d2190aa295c4d70360",
"canvaskit/skwasm_heavy.js.symbols": "3c01ec03b5de6d62c34e17014d1decd3",
"canvaskit/skwasm.wasm": "264db41426307cfc7fa44b95a7772109",
"canvaskit/chromium/canvaskit.js.symbols": "193deaca1a1424049326d4a91ad1d88d",
"canvaskit/chromium/canvaskit.js": "5e27aae346eee469027c80af0751d53d",
"canvaskit/chromium/canvaskit.wasm": "24c77e750a7fa6d474198905249ff506",
"canvaskit/canvaskit.js": "140ccb7d34d0a55065fbd422b843add6",
"canvaskit/canvaskit.wasm": "07b9f5853202304d3b0749d9306573cc",
"canvaskit/skwasm_heavy.wasm": "8034ad26ba2485dab2fd49bdd786837b"};
// The application shell files that are downloaded before a service worker can
// start.
const CORE = ["main.dart.js",
"index.html",
"flutter_bootstrap.js",
"assets/AssetManifest.bin.json",
"assets/FontManifest.json"];

// During install, the TEMP cache is populated with the application shell files.
self.addEventListener("install", (event) => {
  self.skipWaiting();
  return event.waitUntil(
    caches.open(TEMP).then((cache) => {
      return cache.addAll(
        CORE.map((value) => new Request(value, {'cache': 'reload'})));
    })
  );
});
// During activate, the cache is populated with the temp files downloaded in
// install. If this service worker is upgrading from one with a saved
// MANIFEST, then use this to retain unchanged resource files.
self.addEventListener("activate", function(event) {
  return event.waitUntil(async function() {
    try {
      var contentCache = await caches.open(CACHE_NAME);
      var tempCache = await caches.open(TEMP);
      var manifestCache = await caches.open(MANIFEST);
      var manifest = await manifestCache.match('manifest');
      // When there is no prior manifest, clear the entire cache.
      if (!manifest) {
        await caches.delete(CACHE_NAME);
        contentCache = await caches.open(CACHE_NAME);
        for (var request of await tempCache.keys()) {
          var response = await tempCache.match(request);
          await contentCache.put(request, response);
        }
        await caches.delete(TEMP);
        // Save the manifest to make future upgrades efficient.
        await manifestCache.put('manifest', new Response(JSON.stringify(RESOURCES)));
        // Claim client to enable caching on first launch
        self.clients.claim();
        return;
      }
      var oldManifest = await manifest.json();
      var origin = self.location.origin;
      for (var request of await contentCache.keys()) {
        var key = request.url.substring(origin.length + 1);
        if (key == "") {
          key = "/";
        }
        // If a resource from the old manifest is not in the new cache, or if
        // the MD5 sum has changed, delete it. Otherwise the resource is left
        // in the cache and can be reused by the new service worker.
        if (!RESOURCES[key] || RESOURCES[key] != oldManifest[key]) {
          await contentCache.delete(request);
        }
      }
      // Populate the cache with the app shell TEMP files, potentially overwriting
      // cache files preserved above.
      for (var request of await tempCache.keys()) {
        var response = await tempCache.match(request);
        await contentCache.put(request, response);
      }
      await caches.delete(TEMP);
      // Save the manifest to make future upgrades efficient.
      await manifestCache.put('manifest', new Response(JSON.stringify(RESOURCES)));
      // Claim client to enable caching on first launch
      self.clients.claim();
      return;
    } catch (err) {
      // On an unhandled exception the state of the cache cannot be guaranteed.
      console.error('Failed to upgrade service worker: ' + err);
      await caches.delete(CACHE_NAME);
      await caches.delete(TEMP);
      await caches.delete(MANIFEST);
    }
  }());
});
// The fetch handler redirects requests for RESOURCE files to the service
// worker cache.
self.addEventListener("fetch", (event) => {
  if (event.request.method !== 'GET') {
    return;
  }
  var origin = self.location.origin;
  var key = event.request.url.substring(origin.length + 1);
  // Redirect URLs to the index.html
  if (key.indexOf('?v=') != -1) {
    key = key.split('?v=')[0];
  }
  if (event.request.url == origin || event.request.url.startsWith(origin + '/#') || key == '') {
    key = '/';
  }
  // If the URL is not the RESOURCE list then return to signal that the
  // browser should take over.
  if (!RESOURCES[key]) {
    return;
  }
  // If the URL is the index.html, perform an online-first request.
  if (key == '/') {
    return onlineFirst(event);
  }
  event.respondWith(caches.open(CACHE_NAME)
    .then((cache) =>  {
      return cache.match(event.request).then((response) => {
        // Either respond with the cached resource, or perform a fetch and
        // lazily populate the cache only if the resource was successfully fetched.
        return response || fetch(event.request).then((response) => {
          if (response && Boolean(response.ok)) {
            cache.put(event.request, response.clone());
          }
          return response;
        });
      })
    })
  );
});
self.addEventListener('message', (event) => {
  // SkipWaiting can be used to immediately activate a waiting service worker.
  // This will also require a page refresh triggered by the main worker.
  if (event.data === 'skipWaiting') {
    self.skipWaiting();
    return;
  }
  if (event.data === 'downloadOffline') {
    downloadOffline();
    return;
  }
});
// Download offline will check the RESOURCES for all files not in the cache
// and populate them.
async function downloadOffline() {
  var resources = [];
  var contentCache = await caches.open(CACHE_NAME);
  var currentContent = {};
  for (var request of await contentCache.keys()) {
    var key = request.url.substring(origin.length + 1);
    if (key == "") {
      key = "/";
    }
    currentContent[key] = true;
  }
  for (var resourceKey of Object.keys(RESOURCES)) {
    if (!currentContent[resourceKey]) {
      resources.push(resourceKey);
    }
  }
  return contentCache.addAll(resources);
}
// Attempt to download the resource online before falling back to
// the offline cache.
function onlineFirst(event) {
  return event.respondWith(
    fetch(event.request).then((response) => {
      return caches.open(CACHE_NAME).then((cache) => {
        cache.put(event.request, response.clone());
        return response;
      });
    }).catch((error) => {
      return caches.open(CACHE_NAME).then((cache) => {
        return cache.match(event.request).then((response) => {
          if (response != null) {
            return response;
          }
          throw error;
        });
      });
    })
  );
}
