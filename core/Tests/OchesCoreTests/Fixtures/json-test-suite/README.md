Invalid JSON cases from https://github.com/nst/JSONTestSuite/tree/1ef36fa01286573e846ac449e8683f8833c5b26a/test_parsing, MIT license; see LICENSE. These are test inputs, not application data. Each is wrapped as an object member for the wire's top-level object requirement.

The suite also includes 95 JSON-valid examples. Two contain duplicate keys and are intentionally rejected by the JCS/wire policy; the remaining 93 are tested using the internal general parser. This does not establish wire acceptance for numeric or top-level restrictions.
