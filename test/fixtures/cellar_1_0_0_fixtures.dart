// GENERATED ONCE by running cellar 1.0.0's stored format (commit f30ff44,
// before metadata keys moved under `cellar.`): the raw records its decorators
// wrote. Do not regenerate with newer code: the point is that this is what an
// OLDER cellar left on disk, and newer code must still read it.
//
// `records`: the raw backing store, key -> {bytes (base64), contentType, metadata}.
// `objects`: what each logical key must read back as, through the new code.
// Plaintext of an object is `List.generate(size, (i) => (i * 7 + seed) & 0xff)`.

const Map<String, Object?> cellar100Fixtures = {
  "chunked": {
    "chunkSize": 64,
    "records": {
      "doc__manifest": {
        "bytes": "",
        "contentType": "application/pdf",
        "metadata": {
          "generation": "1",
          "chunkCount": "3",
          "totalSize": "150",
          "owner": "u1",
        },
      },
      "small__g0__c0": {
        "bytes": "AgkQFx4lLDM6QQ==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "small__manifest": {
        "bytes": "",
        "contentType": null,
        "metadata": {"generation": "0", "chunkCount": "1", "totalSize": "10"},
      },
      "doc__g1__c0": {
        "bytes":
            "AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dzj6vH4/wYNFBsiKTA3PkVMU1phaG92fYSLkpmgp661vA==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "doc__g1__c1": {
        "bytes":
            "w8rR2N/m7fT7AgkQFx4lLDM6QUhPVl1ka3J5gIeOlZyjqrG4v8bN1Nvi6fD3/gUMExohKC82PURLUllgZ251fA==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "doc__g1__c2": {
        "bytes": "g4qRmJ+mrbS7wsnQ197l7PP6AQgPFg==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
    },
    "objects": {
      "doc": {
        "size": 150,
        "seed": 3,
        "contentType": "application/pdf",
        "metadata": {"owner": "u1"},
      },
      "small": {
        "size": 10,
        "seed": 2,
        "contentType": null,
        "metadata": <String, Object?>{},
      },
    },
  },
  "encrypted": {
    "records": {
      "buffered": {
        "bytes":
            "RkFLRWQAAAAAAAAAAAAEAA4oLzY9REtSWWBnb3Z9hItiYmptVVVLGFcmMzcxJxIYBh6v4vXu+MzUx8+zreK9uJ2Nm4F0cnxwMUhPSF5WPjkhKQdEGxIH4+Xr7tTaypvWobK0sJiTm4eZLmF0YXlPVUBOMCx9PDscChoC9f3987DPzsvfAAA1lQ==",
        "contentType": "text/plain",
        "metadata": {"owner": "u1", "encrypted": "true", "originalSize": "100"},
      },
      "streamed": {
        "bytes":
            "RkFLRQAAAAAAAAAAAAAEADU9RUxTWmFob3Z9hIuSmaFjZWtuVFpKG1YhMjQwGBMbBxmu4fTh+c/VwM6wrP28u5yKmoJ1fX1zME9OS18pPzogLgZHGh0G4OTs79fb1ZrVoLW1s5mcmoSYKWB3YEZOVkFJMS98MzofCx0D9vzi8rPOycrcqLC7o6+BxpmceWFnbWhWWFQVVCM0MjIaHQUFG6jn9uPHwdfCyLau/7KFnoichHd/Y30AAFAr",
        "contentType": null,
        "metadata": {"owner": "u2", "encrypted": "true", "originalSize": "150"},
      },
      "plain": {
        "bytes": "Bg0UGyIpMDc+RUxTWmFob3Z9hIuSmaCnrrW8w8rR",
        "contentType": "image/png",
        "metadata": <String, Object?>{},
      },
    },
    "objects": {
      "buffered": {
        "size": 100,
        "seed": 4,
        "contentType": "text/plain",
        "metadata": {"owner": "u1"},
        "encrypted": true,
      },
      "streamed": {
        "size": 150,
        "seed": 5,
        "contentType": null,
        "metadata": {"owner": "u2"},
        "encrypted": true,
      },
      "plain": {
        "size": 30,
        "seed": 6,
        "contentType": "image/png",
        "metadata": <String, Object?>{},
        "encrypted": false,
      },
    },
  },
  "encryptedOverChunked": {
    "chunkSize": 64,
    "records": {
      "both__g0__c0": {
        "bytes":
            "RkFLRSwBAAAAAAAAAAAEAJCXnqWss7rByM/W3uXs8/phZ21oVlhUFVQjNDIyGh0FBRuo5/bjx8HXwsi2rv+yhQ==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "both__g0__c1": {
        "bytes":
            "noichHd/Y30yTUhNXSsxJCIsAEEYH/ju5u7p0dnXlKuit7O1m56EiporZnFiREBIQ0s3KX4xBBEJHwXw/uD8jQ==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "both__g0__c2": {
        "bytes":
            "zMvM2qqypa2tg8CfnntveW9qUF5WFyotNjA0HB8HC+Wq5fDlxcPJzMq0qPmwh5CWnoZxeWF/DENKT1stMyYsEg==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "both__g0__c3": {
        "bytes":
            "AkMeGfrs+ODr09/RlqmsqbG3nZiGiGQlZHNkQkJKTTU1K3g3BhMXEQfy+Ob+j8LVztistKevk43CnZh9bXthVA==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "both__g0__c4": {
        "bytes":
            "UlxQESgvKD42HhkBCeek+/Lnw8XLzrS6qvu2gZKUkHhze2d5DkFUQVkvNSAuEAxdHBv86vri1d3d05Cvrqu/iQ==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "both__g0__c5": {
        "bytes": "n5qAjmYnen1mQERMAACemQ==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "both__manifest": {
        "bytes": "",
        "contentType": "video/mp4",
        "metadata": {
          "generation": "0",
          "chunkCount": "6",
          "totalSize": "336",
          "owner": "u3",
          "encrypted": "true",
          "originalSize": "300",
        },
      },
      "streamed__g0__c0": {
        "bytes":
            "RkFLRQAAAAAAAAAAAAAEAI2VnKOqsbi/xs3U3OPq8fhuZm5pUVlXFCsiNzM1Gx4EChqr5vHixMDIw8u3qf6xhA==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "streamed__g0__c1": {
        "bytes":
            "kYmfhXB+YHwNTEtMWioyJS0tA0AfHvvv+e/q0N7Wl6qttrC0nJ+Hi2UqZXBlRUNJTEo0KHkwBxAWHgbx+eH/jA==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "streamed__g0__c2": {
        "bytes":
            "w8rP262zpqySgsOemXpseGBrU19RFiksKTE3HRgGCOSl5PPkwsLKzbW1q/i3hpOXkYdyeGZ+D0JVTlgsNCcvEw==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "streamed__g0__c3": {
        "bytes":
            "DUIdGP3t++HU0tzQkaivqL62npmBiWcke3JnQ0VLTjQ6Kns2ARIUEPjz++f5jsHUwdmvtaCukIzdnJt8AAB4mg==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "streamed__manifest": {
        "bytes": "",
        "contentType": null,
        "metadata": {
          "generation": "0",
          "chunkCount": "4",
          "totalSize": "256",
          "owner": "u3",
          "encrypted": "true",
          "originalSize": "220",
        },
      },
      "plain__g0__c0": {
        "bytes":
            "CRAXHiUsMzpBSE9WXWRrcnmAh46VnKOqsbi/xs3U2+Lp8Pf+BQwTGiEoLzY9REtSWWBnbnV8g4qRmJ+mrbS7wg==",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "plain__g0__c1": {
        "bytes": "ydDX3uXs",
        "contentType": null,
        "metadata": <String, Object?>{},
      },
      "plain__manifest": {
        "bytes": "",
        "contentType": null,
        "metadata": {"generation": "0", "chunkCount": "2", "totalSize": "70"},
      },
    },
    "objects": {
      "both": {
        "size": 300,
        "seed": 7,
        "contentType": "video/mp4",
        "metadata": {"owner": "u3"},
        "encrypted": true,
      },
      "streamed": {
        "size": 220,
        "seed": 8,
        "contentType": null,
        "metadata": {"owner": "u3"},
        "encrypted": true,
      },
      "plain": {
        "size": 70,
        "seed": 9,
        "contentType": null,
        "metadata": <String, Object?>{},
        "encrypted": false,
      },
    },
  },
};
