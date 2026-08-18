"""HRR phase-vector algebra, ported from tw_hrr.hpp.

Plate (1995) Holographic Reduced Representations; Gayler (2004) VSA.
Atom vectors must be byte-identical to the C++ and to thirdparty/taskweft-planner's
holographic.py, which is what makes a vector written here readable there.
"""
import hashlib, math, struct

TWO_PI = 6.283185307179586
DIM = 4096
PUNCT = ".,!?;:\"'()[]{}-"
ROLE_CONTENT = "__hrr_role_content__"
ROLE_ENTITY = "__hrr_role_entity__"


def encode_atom(word, dim=DIM):
    """SHA-256 counter blocks -> phases in [0, 2pi)."""
    phases = []
    blocks = (dim + 15) // 16
    for i in range(blocks):
        if len(phases) >= dim:
            break
        digest = hashlib.sha256(f"{word}:{i}".encode()).digest()
        for j in range(0, 32, 2):
            if len(phases) >= dim:
                break
            val = digest[j] | (digest[j + 1] << 8)
            phases.append(val * (TWO_PI / 65536.0))
    return phases


def bind(a, b):
    return [math.fmod(x + y, TWO_PI) for x, y in zip(a, b)]


def unbind(memory, key):
    out = []
    for m, k in zip(memory, key):
        v = math.fmod(m - k, TWO_PI)
        if v < 0.0:
            v += TWO_PI
        out.append(v)
    return out


def bundle(vecs):
    """Superposition by circular mean, so similarity(v_k, bundle) ~ 1/N."""
    if not vecs:
        return []
    dim = len(vecs[0])
    out = []
    for i in range(dim):
        s = sum(math.sin(v[i]) for v in vecs)
        c = sum(math.cos(v[i]) for v in vecs)
        a = math.atan2(s, c)
        out.append(a + TWO_PI if a < 0.0 else a)
    return out


def similarity(a, b):
    if not a:
        return 0.0
    return sum(math.cos(x - y) for x, y in zip(a, b)) / len(a)


def snr_estimate(dim, n_items):
    return 1e18 if n_items <= 0 else math.sqrt(dim / n_items)


def tokenize(text):
    tokens, word = [], []
    def flush():
        if not word:
            return
        w = "".join(word).strip(PUNCT)
        if w:
            tokens.append(w)
        word.clear()
    for ch in text:
        if ch.isspace():
            flush()
        else:
            word.append(ch.lower())
    flush()
    return tokens


def encode_text(text, dim=DIM):
    toks = tokenize(text)
    if not toks:
        return encode_atom("__hrr_empty__", dim)
    return bundle([encode_atom(t, dim) for t in toks])


def encode_binding(content, entity, dim=DIM):
    return bind(encode_text(content, dim), encode_atom(entity.lower(), dim))


def encode_fact(content, entities, dim=DIM):
    parts = [bind(encode_text(content, dim), encode_atom(ROLE_CONTENT, dim))]
    for e in entities:
        parts.append(bind(encode_atom(e.lower(), dim), encode_atom(ROLE_ENTITY, dim)))
    return bundle(parts)


# ---- Interchange: float64, byte-identical to tw_hrr.hpp -------------------
# This is the format the C++ phases_to_bytes/bytes_to_phases read and write.
# Use it when a vector crosses a language boundary.

def phases_to_bytes(phases):
    return struct.pack(f"<{len(phases)}d", *phases)


def bytes_to_phases(blob):
    return list(struct.unpack(f"<{len(blob)//8}d", blob))


# ---- Storage: uint16 phase grid ------------------------------------------
# encode_atom builds every phase as val * (2*pi / 65536) for a uint16 val, so
# the uint16 grid is the one atoms already live on: quantising to it is exact
# for an atom and loses at most half a grid step, 4.8e-5 rad, for a bundle.
#
# It is a quarter the size of float64, and it removes a defect rather than
# trading one. bundle() sums sin and cos, float addition is not associative, so
# in float64 the same components in a different order differ in the last bits.
# Rounding to the grid absorbs that: the bytes are then equal regardless of the
# order the components arrived in.

_Q = 65536.0 / TWO_PI


def phases_to_u16(phases):
    return struct.pack(f"<{len(phases)}H", *(int(round(p * _Q)) % 65536 for p in phases))


def u16_to_phases(blob):
    step = TWO_PI / 65536.0
    return [v * step for v in struct.unpack(f"<{len(blob)//2}H", blob)]
