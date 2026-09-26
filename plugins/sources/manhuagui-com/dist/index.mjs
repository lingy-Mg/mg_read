import { createRequire as __mgreadCreateRequire } from 'node:module'; const require = __mgreadCreateRequire(import.meta.url);
var __create = Object.create;
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getProtoOf = Object.getPrototypeOf;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __commonJS = (cb, mod) => function __require() {
  try {
    return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
  } catch (e) {
    throw mod = 0, e;
  }
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
  // If the importer is in node compatibility mode or this is not an ESM
  // file that has been converted to a CommonJS file using a Babel-
  // compatible transform (i.e. "__esModule" has not been set), then set
  // "default" to the CommonJS "module.exports" for node compatibility.
  isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
  mod
));

// node_modules/lz-string/libs/lz-string.js
var require_lz_string = __commonJS({
  "node_modules/lz-string/libs/lz-string.js"(exports, module) {
    var LZString2 = (function() {
      var f = String.fromCharCode;
      var keyStrBase64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
      var keyStrUriSafe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-$";
      var baseReverseDic = {};
      function getBaseValue(alphabet, character) {
        if (!baseReverseDic[alphabet]) {
          baseReverseDic[alphabet] = {};
          for (var i = 0; i < alphabet.length; i++) {
            baseReverseDic[alphabet][alphabet.charAt(i)] = i;
          }
        }
        return baseReverseDic[alphabet][character];
      }
      var LZString3 = {
        compressToBase64: function(input) {
          if (input == null) return "";
          var res = LZString3._compress(input, 6, function(a) {
            return keyStrBase64.charAt(a);
          });
          switch (res.length % 4) {
            // To produce valid Base64
            default:
            // When could this happen ?
            case 0:
              return res;
            case 1:
              return res + "===";
            case 2:
              return res + "==";
            case 3:
              return res + "=";
          }
        },
        decompressFromBase64: function(input) {
          if (input == null) return "";
          if (input == "") return null;
          return LZString3._decompress(input.length, 32, function(index) {
            return getBaseValue(keyStrBase64, input.charAt(index));
          });
        },
        compressToUTF16: function(input) {
          if (input == null) return "";
          return LZString3._compress(input, 15, function(a) {
            return f(a + 32);
          }) + " ";
        },
        decompressFromUTF16: function(compressed) {
          if (compressed == null) return "";
          if (compressed == "") return null;
          return LZString3._decompress(compressed.length, 16384, function(index) {
            return compressed.charCodeAt(index) - 32;
          });
        },
        //compress into uint8array (UCS-2 big endian format)
        compressToUint8Array: function(uncompressed) {
          var compressed = LZString3.compress(uncompressed);
          var buf = new Uint8Array(compressed.length * 2);
          for (var i = 0, TotalLen = compressed.length; i < TotalLen; i++) {
            var current_value = compressed.charCodeAt(i);
            buf[i * 2] = current_value >>> 8;
            buf[i * 2 + 1] = current_value % 256;
          }
          return buf;
        },
        //decompress from uint8array (UCS-2 big endian format)
        decompressFromUint8Array: function(compressed) {
          if (compressed === null || compressed === void 0) {
            return LZString3.decompress(compressed);
          } else {
            var buf = new Array(compressed.length / 2);
            for (var i = 0, TotalLen = buf.length; i < TotalLen; i++) {
              buf[i] = compressed[i * 2] * 256 + compressed[i * 2 + 1];
            }
            var result = [];
            buf.forEach(function(c) {
              result.push(f(c));
            });
            return LZString3.decompress(result.join(""));
          }
        },
        //compress into a string that is already URI encoded
        compressToEncodedURIComponent: function(input) {
          if (input == null) return "";
          return LZString3._compress(input, 6, function(a) {
            return keyStrUriSafe.charAt(a);
          });
        },
        //decompress from an output of compressToEncodedURIComponent
        decompressFromEncodedURIComponent: function(input) {
          if (input == null) return "";
          if (input == "") return null;
          input = input.replace(/ /g, "+");
          return LZString3._decompress(input.length, 32, function(index) {
            return getBaseValue(keyStrUriSafe, input.charAt(index));
          });
        },
        compress: function(uncompressed) {
          return LZString3._compress(uncompressed, 16, function(a) {
            return f(a);
          });
        },
        _compress: function(uncompressed, bitsPerChar, getCharFromInt) {
          if (uncompressed == null) return "";
          var i, value, context_dictionary = {}, context_dictionaryToCreate = {}, context_c = "", context_wc = "", context_w = "", context_enlargeIn = 2, context_dictSize = 3, context_numBits = 2, context_data = [], context_data_val = 0, context_data_position = 0, ii;
          for (ii = 0; ii < uncompressed.length; ii += 1) {
            context_c = uncompressed.charAt(ii);
            if (!Object.prototype.hasOwnProperty.call(context_dictionary, context_c)) {
              context_dictionary[context_c] = context_dictSize++;
              context_dictionaryToCreate[context_c] = true;
            }
            context_wc = context_w + context_c;
            if (Object.prototype.hasOwnProperty.call(context_dictionary, context_wc)) {
              context_w = context_wc;
            } else {
              if (Object.prototype.hasOwnProperty.call(context_dictionaryToCreate, context_w)) {
                if (context_w.charCodeAt(0) < 256) {
                  for (i = 0; i < context_numBits; i++) {
                    context_data_val = context_data_val << 1;
                    if (context_data_position == bitsPerChar - 1) {
                      context_data_position = 0;
                      context_data.push(getCharFromInt(context_data_val));
                      context_data_val = 0;
                    } else {
                      context_data_position++;
                    }
                  }
                  value = context_w.charCodeAt(0);
                  for (i = 0; i < 8; i++) {
                    context_data_val = context_data_val << 1 | value & 1;
                    if (context_data_position == bitsPerChar - 1) {
                      context_data_position = 0;
                      context_data.push(getCharFromInt(context_data_val));
                      context_data_val = 0;
                    } else {
                      context_data_position++;
                    }
                    value = value >> 1;
                  }
                } else {
                  value = 1;
                  for (i = 0; i < context_numBits; i++) {
                    context_data_val = context_data_val << 1 | value;
                    if (context_data_position == bitsPerChar - 1) {
                      context_data_position = 0;
                      context_data.push(getCharFromInt(context_data_val));
                      context_data_val = 0;
                    } else {
                      context_data_position++;
                    }
                    value = 0;
                  }
                  value = context_w.charCodeAt(0);
                  for (i = 0; i < 16; i++) {
                    context_data_val = context_data_val << 1 | value & 1;
                    if (context_data_position == bitsPerChar - 1) {
                      context_data_position = 0;
                      context_data.push(getCharFromInt(context_data_val));
                      context_data_val = 0;
                    } else {
                      context_data_position++;
                    }
                    value = value >> 1;
                  }
                }
                context_enlargeIn--;
                if (context_enlargeIn == 0) {
                  context_enlargeIn = Math.pow(2, context_numBits);
                  context_numBits++;
                }
                delete context_dictionaryToCreate[context_w];
              } else {
                value = context_dictionary[context_w];
                for (i = 0; i < context_numBits; i++) {
                  context_data_val = context_data_val << 1 | value & 1;
                  if (context_data_position == bitsPerChar - 1) {
                    context_data_position = 0;
                    context_data.push(getCharFromInt(context_data_val));
                    context_data_val = 0;
                  } else {
                    context_data_position++;
                  }
                  value = value >> 1;
                }
              }
              context_enlargeIn--;
              if (context_enlargeIn == 0) {
                context_enlargeIn = Math.pow(2, context_numBits);
                context_numBits++;
              }
              context_dictionary[context_wc] = context_dictSize++;
              context_w = String(context_c);
            }
          }
          if (context_w !== "") {
            if (Object.prototype.hasOwnProperty.call(context_dictionaryToCreate, context_w)) {
              if (context_w.charCodeAt(0) < 256) {
                for (i = 0; i < context_numBits; i++) {
                  context_data_val = context_data_val << 1;
                  if (context_data_position == bitsPerChar - 1) {
                    context_data_position = 0;
                    context_data.push(getCharFromInt(context_data_val));
                    context_data_val = 0;
                  } else {
                    context_data_position++;
                  }
                }
                value = context_w.charCodeAt(0);
                for (i = 0; i < 8; i++) {
                  context_data_val = context_data_val << 1 | value & 1;
                  if (context_data_position == bitsPerChar - 1) {
                    context_data_position = 0;
                    context_data.push(getCharFromInt(context_data_val));
                    context_data_val = 0;
                  } else {
                    context_data_position++;
                  }
                  value = value >> 1;
                }
              } else {
                value = 1;
                for (i = 0; i < context_numBits; i++) {
                  context_data_val = context_data_val << 1 | value;
                  if (context_data_position == bitsPerChar - 1) {
                    context_data_position = 0;
                    context_data.push(getCharFromInt(context_data_val));
                    context_data_val = 0;
                  } else {
                    context_data_position++;
                  }
                  value = 0;
                }
                value = context_w.charCodeAt(0);
                for (i = 0; i < 16; i++) {
                  context_data_val = context_data_val << 1 | value & 1;
                  if (context_data_position == bitsPerChar - 1) {
                    context_data_position = 0;
                    context_data.push(getCharFromInt(context_data_val));
                    context_data_val = 0;
                  } else {
                    context_data_position++;
                  }
                  value = value >> 1;
                }
              }
              context_enlargeIn--;
              if (context_enlargeIn == 0) {
                context_enlargeIn = Math.pow(2, context_numBits);
                context_numBits++;
              }
              delete context_dictionaryToCreate[context_w];
            } else {
              value = context_dictionary[context_w];
              for (i = 0; i < context_numBits; i++) {
                context_data_val = context_data_val << 1 | value & 1;
                if (context_data_position == bitsPerChar - 1) {
                  context_data_position = 0;
                  context_data.push(getCharFromInt(context_data_val));
                  context_data_val = 0;
                } else {
                  context_data_position++;
                }
                value = value >> 1;
              }
            }
            context_enlargeIn--;
            if (context_enlargeIn == 0) {
              context_enlargeIn = Math.pow(2, context_numBits);
              context_numBits++;
            }
          }
          value = 2;
          for (i = 0; i < context_numBits; i++) {
            context_data_val = context_data_val << 1 | value & 1;
            if (context_data_position == bitsPerChar - 1) {
              context_data_position = 0;
              context_data.push(getCharFromInt(context_data_val));
              context_data_val = 0;
            } else {
              context_data_position++;
            }
            value = value >> 1;
          }
          while (true) {
            context_data_val = context_data_val << 1;
            if (context_data_position == bitsPerChar - 1) {
              context_data.push(getCharFromInt(context_data_val));
              break;
            } else context_data_position++;
          }
          return context_data.join("");
        },
        decompress: function(compressed) {
          if (compressed == null) return "";
          if (compressed == "") return null;
          return LZString3._decompress(compressed.length, 32768, function(index) {
            return compressed.charCodeAt(index);
          });
        },
        _decompress: function(length, resetValue, getNextValue) {
          var dictionary = [], next, enlargeIn = 4, dictSize = 4, numBits = 3, entry = "", result = [], i, w, bits, resb, maxpower, power, c, data = { val: getNextValue(0), position: resetValue, index: 1 };
          for (i = 0; i < 3; i += 1) {
            dictionary[i] = i;
          }
          bits = 0;
          maxpower = Math.pow(2, 2);
          power = 1;
          while (power != maxpower) {
            resb = data.val & data.position;
            data.position >>= 1;
            if (data.position == 0) {
              data.position = resetValue;
              data.val = getNextValue(data.index++);
            }
            bits |= (resb > 0 ? 1 : 0) * power;
            power <<= 1;
          }
          switch (next = bits) {
            case 0:
              bits = 0;
              maxpower = Math.pow(2, 8);
              power = 1;
              while (power != maxpower) {
                resb = data.val & data.position;
                data.position >>= 1;
                if (data.position == 0) {
                  data.position = resetValue;
                  data.val = getNextValue(data.index++);
                }
                bits |= (resb > 0 ? 1 : 0) * power;
                power <<= 1;
              }
              c = f(bits);
              break;
            case 1:
              bits = 0;
              maxpower = Math.pow(2, 16);
              power = 1;
              while (power != maxpower) {
                resb = data.val & data.position;
                data.position >>= 1;
                if (data.position == 0) {
                  data.position = resetValue;
                  data.val = getNextValue(data.index++);
                }
                bits |= (resb > 0 ? 1 : 0) * power;
                power <<= 1;
              }
              c = f(bits);
              break;
            case 2:
              return "";
          }
          dictionary[3] = c;
          w = c;
          result.push(c);
          while (true) {
            if (data.index > length) {
              return "";
            }
            bits = 0;
            maxpower = Math.pow(2, numBits);
            power = 1;
            while (power != maxpower) {
              resb = data.val & data.position;
              data.position >>= 1;
              if (data.position == 0) {
                data.position = resetValue;
                data.val = getNextValue(data.index++);
              }
              bits |= (resb > 0 ? 1 : 0) * power;
              power <<= 1;
            }
            switch (c = bits) {
              case 0:
                bits = 0;
                maxpower = Math.pow(2, 8);
                power = 1;
                while (power != maxpower) {
                  resb = data.val & data.position;
                  data.position >>= 1;
                  if (data.position == 0) {
                    data.position = resetValue;
                    data.val = getNextValue(data.index++);
                  }
                  bits |= (resb > 0 ? 1 : 0) * power;
                  power <<= 1;
                }
                dictionary[dictSize++] = f(bits);
                c = dictSize - 1;
                enlargeIn--;
                break;
              case 1:
                bits = 0;
                maxpower = Math.pow(2, 16);
                power = 1;
                while (power != maxpower) {
                  resb = data.val & data.position;
                  data.position >>= 1;
                  if (data.position == 0) {
                    data.position = resetValue;
                    data.val = getNextValue(data.index++);
                  }
                  bits |= (resb > 0 ? 1 : 0) * power;
                  power <<= 1;
                }
                dictionary[dictSize++] = f(bits);
                c = dictSize - 1;
                enlargeIn--;
                break;
              case 2:
                return result.join("");
            }
            if (enlargeIn == 0) {
              enlargeIn = Math.pow(2, numBits);
              numBits++;
            }
            if (dictionary[c]) {
              entry = dictionary[c];
            } else {
              if (c === dictSize) {
                entry = w + w.charAt(0);
              } else {
                return null;
              }
            }
            result.push(entry);
            dictionary[dictSize++] = w + entry.charAt(0);
            enlargeIn--;
            w = entry;
            if (enlargeIn == 0) {
              enlargeIn = Math.pow(2, numBits);
              numBits++;
            }
          }
        }
      };
      return LZString3;
    })();
    if (typeof define === "function" && define.amd) {
      define(function() {
        return LZString2;
      });
    } else if (typeof module !== "undefined" && module != null) {
      module.exports = LZString2;
    } else if (typeof angular !== "undefined" && angular != null) {
      angular.module("LZString", []).factory("LZString", function() {
        return LZString2;
      });
    }
  }
});

// src/discovery-page.ts
function position(cursor, target) {
  if (cursor === null) return { page: 1, offset: 0 };
  const prefix = target + ":";
  const value = cursor.startsWith(prefix) ? cursor.slice(prefix.length) : "";
  const match = /^(\d+)(?::(\d+))?$/u.exec(value);
  const page = Number(match?.[1]), offset = Number(match?.[2] ?? 0);
  if (!match || !Number.isSafeInteger(page) || page < 1 || page > 1e4 || !Number.isSafeInteger(offset) || offset < 0 || offset > 1e4) throw new Error("Discovery cursor is invalid.");
  return { page, offset };
}
function window(all, target, page, offset, size, hasNext) {
  const values = all.slice(offset, offset + size), next = offset + values.length;
  const cursor = next < all.length ? target + ":" + page + ":" + next : hasNext && all.length > 0 && page < 1e4 ? target + ":" + (page + 1) + ":0" : null;
  return { values, continuation: cursor === null ? null : { target, cursor } };
}

// src/source.ts
var import_lz_string = __toESM(require_lz_string(), 1);
var desktopOrigin = "https://www.manhuagui.com";
var mobileOrigin = "https://m.manhuagui.com";
var defaultImageOrigin = "https://i.hamreus.com";
var packedLimit = 1024 * 1024;
var unpackedLimit = 2 * 1024 * 1024;
var categories = Object.freeze([
  { id: "update", title: "最新更新", path: "/update/" },
  { id: "rank", title: "排行榜", path: "/rank/" },
  { id: "all", title: "漫画大全", path: "/list/" },
  { id: "ongoing", title: "连载漫画", path: "/list/lianzai/" },
  { id: "completed", title: "完结漫画", path: "/list/wanjie/" },
  { id: "japan", title: "日本漫画", path: "/list/japan/" },
  { id: "hongkong", title: "港台漫画", path: "/list/hongkong/" },
  { id: "europe", title: "欧美漫画", path: "/list/europe/" },
  { id: "korea", title: "韩国漫画", path: "/list/korea/" },
  { id: "china", title: "内地漫画", path: "/list/china/" }
]);
var ManhuaguiSource = class {
  constructor(context2) {
    this.context = context2;
  }
  context;
  async home(pageSize) {
    const url = new URL("/update/", mobileOrigin);
    return { items: this.#parseCards(await this.#html(url, mobileOrigin), url).slice(0, boundedPageSize(pageSize)) };
  }
  async category(target, cursor, pageSize) {
    const category = decodeCategory(target);
    const state = position(cursor !== null && /^\d+$/u.test(cursor) ? target + ":" + cursor : cursor, target);
    const { page, offset } = state;
    const url = categoryUrl(category.path, page);
    const html = await this.#html(url, mobileOrigin);
    const all = this.#parseCards(html, url);
    const { values, continuation } = window(all, target, page, offset, boundedPageSize(pageSize), findNextPage(html, category.path, page));
    const items = values.map(toDiscoveryItem);
    return { title: category.title, collectionId: `manhuagui-${category.id}`, items, continuation };
  }
  categoryMetadata() {
    return categories.map((category) => ({
      id: `category-${category.id}`,
      title: category.title,
      target: `category:${category.id}`,
      count: null,
      url: new URL(category.path, mobileOrigin).toString(),
      icon: categoryIcon(category.id)
    }));
  }
  async search(query, pageSize) {
    const normalized = query.trim();
    if (normalized === "") return [];
    const url = new URL(`/s/${encodeURIComponent(normalized)}.html`, mobileOrigin);
    return this.#parseCards(await this.#html(url, mobileOrigin), url).slice(0, boundedPageSize(pageSize));
  }
  async detail(id) {
    const key = decodeBookId(id);
    const url = bookUrl(key);
    const html = await this.#html(url, desktopOrigin);
    const title = textFromMatch(html, /<h1[^>]*>([\s\S]*?)<\/h1>/iu);
    if (title === null) throw new Error("Source detail title is missing.");
    const author = textFromMatch(html, /漫画作者：<\/strong>([\s\S]*?)<\/span>/iu);
    const categoryText = textFromMatch(html, /漫画剧情：<\/strong>([\s\S]*?)<\/span>/iu);
    const statusText = textFromMatch(html, /漫画状态：<\/strong>\s*<span[^>]*>([\s\S]*?)<\/span>/iu);
    const coverBlock = firstCapture(html, /<p[^>]*class=["'][^"']*hcover[^"']*["'][^>]*>([\s\S]*?)<\/p>/iu) ?? "";
    const coverTag = firstCapture(coverBlock, /(<img\b[^>]*>)/iu);
    const cover = normalizeImageUrl(coverTag === null ? void 0 : attribute(coverTag, "src"), url);
    const description = textFromMatch(html, /<div[^>]*id=["']intro-all["'][^>]*>([\s\S]*?)<\/div>/iu) ?? textFromMatch(html, /<div[^>]*id=["']intro-cut["'][^>]*>([\s\S]*?)<\/div>/iu);
    const latestBlock = firstCapture(html, /最近于[\s\S]*?更新至\s*\[([\s\S]*?)\]/iu) ?? "";
    const latestLink = firstLink(latestBlock, /\/comic\/\d+\/\d+\.html$/u);
    const latestUrl = latestLink === void 0 ? null : normalizePageUrl(latestLink.href, url);
    const chapters = parseChapters(html, key);
    const aliases = textFromMatch(html, /漫画别名：<\/strong>([\s\S]*?)<\/span>/iu);
    return {
      ...makeSummary({
        key,
        title,
        author,
        category: categoryText,
        coverUrl: this.#proxyImage(cover, url),
        description,
        status: parseStatus(statusText),
        chapterCount: chapters.length,
        latest: latestUrl === null || latestLink === void 0 || latestLink.title === null ? null : {
          id: chapterIdFromUrl(latestUrl),
          title: latestLink.title,
          url: latestUrl.toString(),
          updatedAt: null
        }
      }),
      aliases: aliases === null || aliases === "暂无" ? [] : [aliases],
      catalogUrl: url.toString()
    };
  }
  async chapters(id) {
    const key = decodeBookId(id);
    const html = await this.#html(bookUrl(key), desktopOrigin);
    return { items: parseChapters(html, key) };
  }
  async content(id, idForChapter) {
    const book = decodeBookId(id);
    const chapter = decodeChapterId(idForChapter);
    if (book.book !== chapter.book) throw new Error("Chapter does not belong to the requested manga.");
    const url = chapterUrl(chapter);
    const html = await this.#html(url, desktopOrigin);
    const data = parsePackedImageData(html);
    const images = buildImageUrls(data);
    if (images.length === 0) throw new Error("Source chapter images are missing.");
    const title = titleWithoutSuffix(textFromMatch(html, /<title[^>]*>([\s\S]*?)<\/title>/iu));
    return {
      chapterId: idForChapter,
      contentKind: "manga",
      title,
      updatedAt: null,
      text: null,
      pages: images.map((image, index) => ({
        id: `page:${chapter.chapter}:${index + 1}`,
        index,
        url: this.#proxyImage(image, url),
        mimeType: mimeType(image),
        width: null,
        height: null
      }))
    };
  }
  #parseCards(html, pageUrl) {
    const list = firstCapture(html, /<div\s+class=["'][^"']*cont-list[^"']*["'][^>]*>[\s\S]*?<ul[^>]*id=["']detail["'][^>]*>([\s\S]*?)<\/ul>/iu) ?? html;
    const output = [];
    const seen = /* @__PURE__ */ new Set();
    for (const item of captures(list, /<li\b[^>]*>([\s\S]*?)<\/li>/giu)) {
      const link = firstLink(item, /\/comic\/\d+\/?$/u);
      if (link === void 0) continue;
      const contentUrl = normalizePageUrl(link.href, pageUrl);
      if (contentUrl === null) continue;
      const key = bookKeyFromUrl(contentUrl);
      if (seen.has(key.book)) continue;
      seen.add(key.book);
      const title = textFromMatch(item, /<h3[^>]*>([\s\S]*?)<\/h3>/iu) ?? link.title;
      if (title === null) continue;
      const imageTag = firstCapture(item, /(<img\b[^>]*>)/iu);
      const cover = normalizeImageUrl(imageTag === null ? void 0 : attribute(imageTag, "data-src") ?? attribute(imageTag, "src"), pageUrl);
      const status = textFromMatch(item, /<i[^>]*>([\s\S]*?)<\/i>/iu);
      const author = definition(item, "作s*者");
      const category = definition(item, "类s*别");
      const latestTitle = definition(item, "更新至");
      const latest = latestTitle === null ? null : { id: null, title: latestTitle, url: null, updatedAt: null };
      output.push(makeSummary({
        key,
        title,
        author,
        category,
        coverUrl: this.#proxyImage(cover, pageUrl),
        description: null,
        status: parseStatus(status),
        chapterCount: null,
        latest
      }));
    }
    return output;
  }
  async #html(url, refererOrigin) {
    if (!allowedPage(url)) throw new Error("Source page URL is invalid.");
    const response = await this.context.http.fetch(url, { headers: { accept: "text/html,application/xhtml+xml", referer: `${refererOrigin}/` } });
    if (!response.ok) {
      if (response.status === 403 || response.status === 429) this.context.errors.raise({ code: "source_access_blocked", message: "访问异常，请稍后再试。", annotation: `HTTP ${response.status}` });
      throw new Error("Source page request failed.");
    }
    const html = await response.text();
    if (/cf-challenge|cf-turnstile|正在检查您的浏览器|人机验证/iu.test(html)) throw new Error("Source interaction is required.");
    return html;
  }
  #proxyImage(url, referer) {
    return url === null || !allowedImage(url) || !allowedReferer(referer) ? null : this.context.resource.proxy({ kind: "manhuagui-image", url: url.toString(), headers: { Accept: "image/*", Referer: referer.toString() } });
  }
};
function parsePackedImageData(html) {
  const code = unpackPackedImageCode(html);
  const json = extractJsonObject(code, "SMH.imgData(");
  let raw;
  try {
    raw = JSON.parse(json);
  } catch {
    throw new Error("Source image data JSON is invalid.");
  }
  if (!isRecord(raw) || !Array.isArray(raw.files)) throw new Error("Source image data shape is invalid.");
  const files = raw.files.flatMap((value) => typeof value === "string" && value !== "" ? [value] : []);
  if (files.length === 0 || files.length > 5e3) throw new Error("Source image count is invalid.");
  const sl = isRecord(raw.sl) ? raw.sl : void 0;
  return {
    files,
    host: stringValue(raw.host) ?? stringValue(raw.domain) ?? stringValue(raw.server) ?? defaultImageOrigin,
    path: stringValue(raw.path) ?? "",
    e: stringValue(sl?.e),
    m: stringValue(sl?.m),
    cid: stringValue(raw.cid),
    md5: stringValue(raw.md5)
  };
}
function unpackPackedImageCode(html) {
  if (html.length > unpackedLimit) throw new Error("Source chapter page is too large.");
  const marker = html.includes("}('") ? html.indexOf("}('") + 2 : html.indexOf('}("') + 2;
  if (marker < 2) throw new Error("Source packed image data is missing.");
  const args = readPackedArgs(html, marker);
  if (args.packed.length > packedLimit || args.count > 4096 || args.radix < 2 || args.radix > 62) throw new Error("Source packed image data exceeds limits.");
  const dictionaryText = args.dictionary.includes("|") ? args.dictionary : import_lz_string.default.decompressFromBase64(args.dictionary);
  if (dictionaryText === null || dictionaryText.length > unpackedLimit) throw new Error("Source packed dictionary is invalid.");
  const code = unpackCode(args.packed, args.radix, args.count, dictionaryText.split("|"));
  if (code.length > unpackedLimit) throw new Error("Source unpacked image data exceeds limits.");
  return code;
}
function buildImageUrls(data) {
  const host = normalizeHost(data.host);
  return data.files.map((file) => {
    const url = /^https?:\/\//iu.test(file) ? new URL(file) : new URL(joinPath(data.path, file), host);
    if (!allowedImage(url)) throw new Error("Source image URL is outside the allowed hosts.");
    if (data.e !== null) url.searchParams.set("e", data.e);
    if (data.m !== null) url.searchParams.set("m", data.m);
    if (data.e === null && data.m === null && data.cid !== null && data.md5 !== null) {
      url.searchParams.set("cid", data.cid);
      url.searchParams.set("md5", data.md5);
    }
    return url;
  });
}
function parseChapters(html, key) {
  const start = html.indexOf("章节全集");
  const scoped = start < 0 ? html : html.slice(start);
  const endCandidates = ['<div class="comment', '<div class="fr w250"'].map((needle) => scoped.indexOf(needle)).filter((value) => value > 0);
  const section = endCandidates.length === 0 ? scoped : scoped.slice(0, Math.min(...endCandidates));
  const seen = /* @__PURE__ */ new Set();
  const output = [];
  for (const link of links(section)) {
    const url = normalizePageUrl(link.href, new URL("/", desktopOrigin));
    if (url === null || !new RegExp(`^/comic/${key.book}/\\d+\\.html$`, "u").test(url.pathname)) continue;
    const chapter = chapterKeyFromUrl(url);
    if (seen.has(chapter.chapter)) continue;
    seen.add(chapter.chapter);
    output.push({ id: encodeChapterId(chapter), title: attribute(link.tag, "title") ?? link.title ?? "章节", order: Number(chapter.chapter), url: url.toString(), volumeTitle: null, wordCount: null, updatedAt: null, isLocked: false, attributes: [] });
  }
  output.sort((left, right) => left.order - right.order);
  return output.map((chapter, order) => ({ ...chapter, order }));
}
function makeSummary(input) {
  return {
    id: encodeBookId(input.key),
    title: input.title,
    contentKind: "manga",
    author: input.author,
    url: bookUrl(input.key).toString(),
    coverUrl: input.coverUrl,
    description: input.description,
    language: "zh-CN",
    status: input.status,
    access: "free",
    wordCount: null,
    chapterCount: input.chapterCount,
    publishedAt: null,
    updatedAt: null,
    latestChapter: input.latest,
    categories: input.category === null ? [] : input.category.split(/[,，]/u).map((value) => value.trim()).filter(Boolean),
    tags: [],
    attributes: []
  };
}
function toDiscoveryItem(content) {
  return { content, rank: null, metric: null, recommendation: null };
}
function boundedPageSize(value) {
  if (!Number.isSafeInteger(value) || value <= 0) throw new Error("Page size is invalid.");
  return Math.min(value, 50);
}
function decodeCategory(target) {
  const id = target.startsWith("category:") ? target.slice(9) : "";
  const value = categories.find((item) => item.id === id);
  if (value === void 0) throw new Error("Category target is invalid.");
  return value;
}
function categoryUrl(path, page) {
  if (page === 1) return new URL(path, mobileOrigin);
  return new URL(`${path.endsWith("/") ? path : `${path}/`}index_p${page}.html`, mobileOrigin);
}
function findNextPage(html, path, page) {
  return links(html).some((link) => new URL(link.href, mobileOrigin).pathname === categoryUrl(path, page + 1).pathname);
}
function categoryIcon(id) {
  return id === "rank" ? "ranking" : id === "completed" ? "completed" : id === "ongoing" ? "ongoing" : id === "update" ? "newRelease" : "manga";
}
function definition(input, label) {
  return textFromMatch(input, new RegExp(`<dt>\\s*${label}\\s*[：:]?\\s*<\\/dt>\\s*<dd>([\\s\\S]*?)<\\/dd>`, "iu"));
}
function parseStatus(value) {
  if (value === null) return "unknown";
  if (/完结|完本/iu.test(value)) return "completed";
  if (/连载/iu.test(value)) return "ongoing";
  if (/停更|暂停/iu.test(value)) return "hiatus";
  return "unknown";
}
function titleWithoutSuffix(value) {
  return value === null ? null : text(value.split("_")[0] ?? value);
}
function encodeBookId(key) {
  return `manga:${key.book}`;
}
function decodeBookId(id) {
  const match = /^manga:(\d+)$/u.exec(id);
  if (match?.[1] === void 0) throw new Error("Content ID is invalid.");
  return { book: match[1] };
}
function bookKeyFromUrl(url) {
  const match = /^\/comic\/(\d+)\/?$/u.exec(url.pathname);
  if (match?.[1] === void 0) throw new Error("Source manga URL is invalid.");
  return { book: match[1] };
}
function encodeChapterId(key) {
  return `chapter:${key.book}:${key.chapter}`;
}
function decodeChapterId(id) {
  const match = /^chapter:(\d+):(\d+)$/u.exec(id);
  if (match?.[1] === void 0 || match[2] === void 0) throw new Error("Chapter ID is invalid.");
  return { book: match[1], chapter: match[2] };
}
function chapterIdFromUrl(url) {
  return encodeChapterId(chapterKeyFromUrl(url));
}
function chapterKeyFromUrl(url) {
  const match = /^\/comic\/(\d+)\/(\d+)\.html$/u.exec(url.pathname);
  if (match?.[1] === void 0 || match[2] === void 0) throw new Error("Source chapter URL is invalid.");
  return { book: match[1], chapter: match[2] };
}
function bookUrl(key) {
  return new URL(`/comic/${key.book}/`, desktopOrigin);
}
function chapterUrl(key) {
  return new URL(`/comic/${key.book}/${key.chapter}.html`, desktopOrigin);
}
function allowedPage(url) {
  return url.protocol === "https:" && (url.origin === desktopOrigin || url.origin === mobileOrigin);
}
function allowedReferer(url) {
  return allowedPage(url) && (/^\/comic\/\d+(?:\/\d+\.html)?\/?$/u.test(url.pathname) || url.origin === mobileOrigin);
}
function allowedImage(url) {
  return url.protocol === "https:" && (url.hostname === "cf.mhgui.com" || url.hostname === "i.hamreus.com") && url.pathname.length > 1;
}
function normalizePageUrl(value, base) {
  if (value === void 0 || value === "") return null;
  const url = new URL(value, base);
  return allowedPage(url) ? new URL(url.pathname + url.search, desktopOrigin) : null;
}
function normalizeImageUrl(value, base) {
  if (value === void 0 || value === "") return null;
  const url = value.startsWith("//") ? new URL(`https:${value}`) : new URL(value, base);
  return allowedImage(url) ? url : null;
}
function normalizeHost(value) {
  const normalized = value.startsWith("//") ? `https:${value}` : /^https?:\/\//iu.test(value) ? value : `https://${value}`;
  const url = new URL(normalized);
  if (!allowedImage(new URL("/placeholder.jpg", url))) throw new Error("Source image host is invalid.");
  return url;
}
function joinPath(path, file) {
  return `/${[path, file].map((value) => value.replace(/^\/+|\/+$/gu, "")).filter(Boolean).join("/")}`;
}
function mimeType(url) {
  const extension = /\.([^.]+)$/u.exec(url.pathname)?.[1]?.toLowerCase();
  return extension === "jpg" || extension === "jpeg" ? "image/jpeg" : extension === "png" ? "image/png" : extension === "webp" ? "image/webp" : extension === "gif" ? "image/gif" : null;
}
function readPackedArgs(input, offset) {
  const packed = readQuoted(input, offset);
  if (packed === null) throw new Error("Packed source argument is invalid.");
  const radix = readNumber(input, skipComma(input, packed.end));
  if (radix === null) throw new Error("Packed radix is invalid.");
  const count = readNumber(input, skipComma(input, radix.end));
  if (count === null) throw new Error("Packed count is invalid.");
  const dictionary = readQuoted(input, skipComma(input, count.end));
  if (dictionary === null) throw new Error("Packed dictionary is invalid.");
  return { packed: packed.value, radix: radix.value, count: count.value, dictionary: dictionary.value };
}
function skipComma(input, offset) {
  let index = offset;
  while (/[\s,]/u.test(input[index] ?? "")) index += 1;
  return index;
}
function readNumber(input, offset) {
  const match = /^\d+/u.exec(input.slice(offset));
  return match === null ? null : { value: Number(match[0]), end: offset + match[0].length };
}
function readQuoted(input, offset) {
  const quote = input[offset];
  if (quote !== "'" && quote !== '"') return null;
  let value = "";
  let index = offset + 1;
  while (index < input.length) {
    const character = input[index];
    if (character === quote) return { value, end: index + 1 };
    if (character !== "\\") {
      value += character;
      index += 1;
      continue;
    }
    const escaped = input[index + 1];
    if (escaped === void 0) return null;
    if (escaped === "x") {
      value += String.fromCharCode(Number.parseInt(input.slice(index + 2, index + 4), 16));
      index += 4;
    } else if (escaped === "u") {
      value += String.fromCharCode(Number.parseInt(input.slice(index + 2, index + 6), 16));
      index += 6;
    } else {
      value += escaped === "n" ? "\n" : escaped === "r" ? "\r" : escaped === "t" ? "	" : escaped;
      index += 2;
    }
  }
  return null;
}
function unpackCode(packed, radix, count, words) {
  const dictionary = /* @__PURE__ */ new Map();
  for (let index = count - 1; index >= 0; index -= 1) {
    const key = baseEncode(index, radix);
    const value = words[index];
    dictionary.set(key, value === void 0 || value === "" ? key : value);
  }
  return packed.replace(/\b\w+\b/gu, (word) => dictionary.get(word) ?? word);
}
function baseEncode(value, radix) {
  const characters = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
  if (value === 0) return "0";
  let output = "";
  let remaining = value;
  while (remaining > 0) {
    output = characters[remaining % radix] + output;
    remaining = Math.floor(remaining / radix);
  }
  return output;
}
function extractJsonObject(code, marker) {
  const markerIndex = code.indexOf(marker);
  const start = code.indexOf("{", markerIndex + marker.length);
  if (markerIndex < 0 || start < 0) throw new Error("Source image object is missing.");
  let depth = 0;
  let quote = "";
  let escaped = false;
  for (let index = start; index < code.length; index += 1) {
    const character = code[index];
    if (quote !== "") {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === quote) quote = "";
      continue;
    }
    if (character === '"' || character === "'") {
      quote = character;
      continue;
    }
    if (character === "{") depth += 1;
    if (character === "}") {
      depth -= 1;
      if (depth === 0) return code.slice(start, index + 1);
    }
  }
  throw new Error("Source image object is incomplete.");
}
function links(input) {
  return [...input.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/giu)].flatMap((match) => {
    const href = attribute(match[1] ?? "", "href");
    return href === void 0 ? [] : [{ href, title: textFromHtml(match[2] ?? ""), tag: match[1] ?? "" }];
  });
}
function firstLink(input, pattern) {
  return links(input).find((link) => pattern.test(link.href));
}
function captures(input, pattern) {
  return [...input.matchAll(pattern)].flatMap((match) => match[1] === void 0 ? [] : [match[1]]);
}
function firstCapture(input, pattern) {
  return input.match(pattern)?.[1] ?? null;
}
function textFromMatch(input, pattern) {
  const value = firstCapture(input, pattern);
  return value === null ? null : textFromHtml(value);
}
function textFromHtml(value) {
  return text(decodeHtml(value.replace(/<script\b[\s\S]*?<\/script>/giu, "").replace(/<style\b[\s\S]*?<\/style>/giu, "").replace(/<[^>]+>/gu, " ")));
}
function text(value) {
  const normalized = value.replace(/\u00a0/gu, " ").replace(/\s+/gu, " ").trim();
  return normalized === "" ? null : normalized;
}
function attribute(tag, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  const match = tag.match(new RegExp(`\\b${escaped}\\s*=\\s*(["'])([\\s\\S]*?)\\1`, "iu"));
  return match?.[2] === void 0 ? void 0 : decodeHtml(match[2]);
}
function decodeHtml(input) {
  const named = { amp: "&", apos: "'", gt: ">", lt: "<", nbsp: " ", quot: '"' };
  return input.replace(/&(#(?:x[0-9a-f]+|\d+)|[a-z]+);/giu, (entity, body) => {
    const value = body.toLowerCase();
    if (value.startsWith("#x")) return String.fromCodePoint(Number.parseInt(value.slice(2), 16));
    if (value.startsWith("#")) return String.fromCodePoint(Number.parseInt(value.slice(1), 10));
    return named[value] ?? entity;
  });
}
function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function stringValue(value) {
  return typeof value === "string" && value !== "" ? value : typeof value === "number" && Number.isFinite(value) ? String(value) : null;
}

// src/index.mts
var context;
var source;
async function activate(nextContext) {
  context = nextContext;
  source = new ManhuaguiSource(nextContext);
  nextContext.log.info("plugin_activated");
}
async function discover(request) {
  return invoke("discover", async (active) => {
    if (request.target === null) {
      if (request.cursor !== null || request.collectionId !== null) throw new Error("Initial discovery request is invalid.");
      const home = await active.category("category:update", null, Math.min(request.pageSize, 10));
      return { kind: "document", document: { components: [
        { type: "section", id: "manhuagui-latest-section", title: "最新更新", subtitle: null, icon: "newRelease", children: [
          { type: "contentCollection", id: home.collectionId, layout: "coverGrid", items: home.items, continuation: home.continuation }
        ] },
        { type: "section", id: "manhuagui-categories-section", title: "漫画分类", subtitle: null, icon: "category", children: [
          { type: "categoryCollection", id: "manhuagui-categories", layout: "chips", categories: active.categoryMetadata() }
        ] }
      ] } };
    }
    const result = await active.category(request.target, request.cursor, request.pageSize);
    if (request.collectionId !== null && request.collectionId !== result.collectionId) throw new Error("Discovery collection is invalid.");
    if (request.collectionId !== null) return { kind: "append", collectionId: result.collectionId, items: result.items, continuation: result.continuation };
    return { kind: "document", document: { components: [
      { type: "section", id: `${result.collectionId}-section`, title: result.title, subtitle: null, children: [
        { type: "contentCollection", id: result.collectionId, layout: "coverGrid", items: result.items, continuation: result.continuation }
      ] }
    ] } };
  });
}
async function search(request) {
  return invoke("search", async (active) => {
    if (request.cursor !== null) throw new Error("Search cursor is not supported.");
    const items = await active.search(request.query, request.pageSize);
    return { items, nextCursor: null, totalCount: null };
  });
}
async function searchSuggestions() {
  return { items: [], nextCursor: null };
}
async function getDetail(request) {
  return invoke("get_detail", (active) => active.detail(request.id));
}
async function getChapters(request) {
  return invoke("get_chapters", (active) => active.chapters(request.id));
}
async function getContent(request) {
  return invoke("get_content", (active) => active.content(request.id, request.chapterId));
}
async function invoke(operation, action) {
  const activeContext = requireValue(context);
  const active = requireValue(source);
  activeContext.log.info(`source_${operation}_started`);
  try {
    const result = await action(active);
    activeContext.log.info(`source_${operation}_completed`);
    return result;
  } catch (error) {
    activeContext.log.warn(`source_${operation}_failed`);
    if (isRuntimeRaisedError(error)) throw error;
    throw new Error("Source operation failed.");
  }
}
function isRuntimeRaisedError(error) {
  if (error === null || typeof error !== "object") return false;
  const candidate = error;
  return candidate.name === "PluginManagerError" && typeof candidate.code === "string";
}
function requireValue(value) {
  if (value === void 0) throw new Error("Source is not activated.");
  return value;
}
export {
  activate,
  discover,
  getChapters,
  getContent,
  getDetail,
  search,
  searchSuggestions
};
