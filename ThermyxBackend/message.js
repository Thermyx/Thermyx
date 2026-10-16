// The texts a trusted contact receives. Plain sentences, most important
// first: who and how serious, what the insoles saw, when, where, and what to
// do. The app's preview (ThermyxCircleMessage.swift) mirrors this file; both
// are checked against test/message-fixtures.json so they say the same thing.

const LEVELS = ["Normal", "Caution", "High risk", "Critical"];
const FEET = ["left", "right", "both"];
const ZONES = ["forefoot", "arch", "heel"];
const CAUSES = ["heatLimit", "hot", "cold", "unsteady", "hotAir", "warmerFoot", "unevenLoad"];
const TRENDS = ["rising", "falling", "steady"];
const UPDATES = ["still", "recovering", "resolved"];

const cap = s => s.charAt(0).toUpperCase() + s.slice(1);

/// Keeps only the fields a message or the watcher card may use, each checked
/// against its allowed values, so nothing else an app sends is stored or
/// texted. Returns null when the detail is missing or unusable.
function cleanDetail(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const d = {};
  if (typeof raw.name === "string") {
    // One line, no control characters, short enough for a header.
    const name = raw.name.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, 40);
    if (name) d.name = name;
  }
  if (FEET.includes(raw.foot)) d.foot = raw.foot;
  if (ZONES.includes(raw.zone) && raw.foot !== "both") d.zone = raw.zone;
  if (Array.isArray(raw.causes)) {
    const causes = [...new Set(raw.causes.filter(c => CAUSES.includes(c)))].slice(0, 3);
    if (causes.length) d.causes = causes;
  }
  if (typeof raw.footC === "number" && Number.isFinite(raw.footC) && raw.footC > 0 && raw.footC < 60) {
    d.footC = Math.round(raw.footC * 10) / 10;
  }
  if (TRENDS.includes(raw.trend)) d.trend = raw.trend;
  if (raw.confidence === "confirmed" || raw.confidence === "limited") d.confidence = raw.confidence;
  if (raw.battery && FEET.slice(0, 2).includes(raw.battery.foot) && Number.isInteger(raw.battery.percent)
      && raw.battery.percent >= 0 && raw.battery.percent <= 100) {
    d.battery = { foot: raw.battery.foot, percent: raw.battery.percent };
  }
  if (raw.connection === "oneInsole" || raw.connection === "stale") d.connection = raw.connection;
  // The wearer's local time, already formatted on their phone ("4:18 PM CDT"),
  // so the text shows their clock and not the server's.
  // iOS puts a narrow no-break space before "PM"; it becomes a plain space
  // so the text stays in the SMS alphabet.
  const time = t => {
    if (typeof t !== "string") return null;
    const plain = t.replace(/[  ]/g, " ").trim();
    return plain.length <= 24 && /^[A-Za-z0-9 :.,+\-]+$/.test(plain) ? plain : null;
  };
  if (time(raw.time)) d.time = time(raw.time);
  if (time(raw.checkedIn)) d.checkedIn = time(raw.checkedIn);
  d.unit = raw.unit === "C" ? "C" : "F";
  if (UPDATES.includes(raw.update)) d.update = raw.update;
  if (Number.isInteger(raw.minutes) && raw.minutes > 0 && raw.minutes < 1000) d.minutes = raw.minutes;
  // An SOS is either the wearer pressing Call 911, or no answer to a
  // Critical alert's countdown.
  if (raw.sos === "pressed" || raw.sos === "noResponse") d.sos = raw.sos;
  return d;
}

function temperature(c, unit) {
  const v = unit === "C" ? c : c * 9 / 5 + 32;
  // No degree sign: "°" isn't in the SMS alphabet and would make the whole
  // text Unicode (70 characters a segment instead of 160).
  return `${v.toFixed(1)}${unit}`;
}

/// "Right forefoot", "Left foot", "Both feet", "Their foot".
function place(d) {
  if (d.foot === "both") return "Both feet";
  if (d.foot && d.zone) return `${cap(d.foot)} ${d.zone}`;
  if (d.foot) return `${cap(d.foot)} foot`;
  return "Their foot";
}

/// What the insoles saw, as one sentence.
function condition(d) {
  const causes = d.causes || [];
  const first = causes[0];
  const t = d.footC !== undefined ? temperature(d.footC, d.unit) : null;
  const plural = d.foot === "both";
  let sentence;
  switch (first) {
    case "heatLimit":
      sentence = `${place(d)} reached the insole's heat limit${t ? ` (${t})` : ""}. Heating has switched off.`;
      break;
    case "hot": {
      const trend = d.trend === "rising" ? " and still rising" : d.trend === "falling" ? " but falling" : "";
      sentence = plural
        ? `Both feet are hot${trend}${t ? `: ${t} at the warmer insole` : ""}.`
        : `${place(d)} temperature is elevated${trend}${t ? `: ${t} at the insole` : ""}.`;
      break;
    }
    case "cold": {
      const trend = d.trend === "falling" ? " and still cooling" : d.trend === "rising" ? " but warming" : "";
      sentence = `${place(d)} ${plural ? "are" : "is"} cold${trend}${t ? `: ${t} at the insole` : ""}.`;
      break;
    }
    case "unsteady": sentence = "Their steps are much less steady than usual."; break;
    case "hotAir": sentence = "The air around them is very hot."; break;
    case "warmerFoot": sentence = `${d.foot && d.foot !== "both" ? `${cap(d.foot)} foot` : "One foot"} is running much warmer than the other.`; break;
    case "unevenLoad": sentence = `They're putting much more weight on ${d.foot && d.foot !== "both" ? `their ${d.foot} foot` : "one foot"}.`; break;
    default: {
      // Nothing flagged now (often while recovering): the reading and its direction.
      const trend = d.trend === "rising" ? " and is rising" : d.trend === "falling" ? " and is falling" : "";
      sentence = t ? `${place(d)} reads ${t} at the insole${trend}.` : null;
    }
  }
  const also = causes.slice(1).map(c => ({
    heatLimit: "the insole hit its heat limit", hot: "foot temperature is high", cold: "a foot is cold",
    unsteady: "their steps are less steady", hotAir: "the air is very hot",
    warmerFoot: "one foot is much warmer", unevenLoad: "their weight is uneven"
  })[c]);
  if (sentence && also.length) sentence += ` Also: ${also.join(" and ")}.`;
  return sentence;
}

/// Whether the reading can be relied on, with the wearer's local time.
function confidence(d) {
  if (!d.confidence) return d.time ? `Reading at ${d.time}.` : null;
  if (d.confidence === "confirmed") return d.time ? `Data confirmed at ${d.time}.` : "Data confirmed.";
  return `Limited data${d.time ? ` at ${d.time}` : ""}: check on them directly.`;
}

/// Only when it matters: a low insole battery or a weak connection.
function equipment(d) {
  const parts = [];
  if (d.battery) parts.push(`${cap(d.battery.foot)} insole battery is at ${d.battery.percent}%.`);
  if (d.connection === "oneInsole") parts.push("Only one insole is connected.");
  if (d.connection === "stale") parts.push("Their readings are more than a minute old.");
  return parts.length ? parts.join(" ") : null;
}

/// Location goes in High risk, Critical and SOS messages: a map link, or a
/// plain statement of why there isn't one.
function locationLine(event, severe) {
  if (!severe) return null;
  if (!event.locationConsent) return "Location not shared.";
  const loc = event.location;
  if (loc && typeof loc.latitude === "number") {
    return `Location: https://maps.google.com/?q=${loc.latitude.toFixed(5)},${loc.longitude.toFixed(5)}`;
  }
  return "Location unavailable.";
}

/// What the contact should do, by level.
function action(level, kind, hasLocation) {
  if (kind === "sos") return `Call them now. If you can't reach them, call 911${hasLocation ? " and give their location" : ""}.`;
  if (level === "Critical") return "Call them now. If they don't answer or seem unresponsive, call 911.";
  if (level === "High risk") return "Call them now.";
  if (level === "Caution") return "Check in with them within 5 minutes.";
  return null;
}

/// What Thermyx told the wearer, so the contact knows what they were asked.
function wearerWasAsked(level) {
  if (level === "Critical") return "Thermyx told them to stop and get help.";
  if (level === "High risk") return "Thermyx told them to stop, drink water and cool down.";
  return null;
}

const FOLLOW_UP = "Thermyx will text again when they check in or readings recover.";

function header(event, name) {
  const kind = event.kind || "alert";
  if (kind === "sos") return `Thermyx SOS - ${name}`;
  if (kind === "alert") return `Thermyx ${event.level === "High risk" ? "High-Risk" : event.level} Alert - ${name}`;
  return `Thermyx update - ${name}`;
}

/// The whole text. `detail` should already be cleaned (cleanDetail).
function composeMessage(event, detail) {
  const d = detail || { unit: "F" };
  const kind = event.kind || "alert";
  const level = event.level;
  const name = d.name || "your contact";
  const severe = kind === "sos" || level === "High risk" || level === "Critical";
  const lines = [header(event, name)];
  const push = line => { if (line) lines.push(line); };

  if (kind === "ok") {
    push(`${d.name || "They"} checked in${d.checkedIn ? ` at ${d.checkedIn}` : ""} and ${d.name ? "says they're" : "say they're"} OK.`);
    if (level === "High risk" || level === "Critical") push(`Readings are still ${level}, so stay in touch.`);
    return lines.join("\n");
  }

  if (kind === "update") {
    if (d.update === "resolved") {
      push(`Readings are back to Normal${d.time ? ` as of ${d.time}` : ""}.`);
      return lines.join("\n");
    }
    if (d.update === "recovering") {
      push(`Readings are recovering: now ${level}${d.time ? ` as of ${d.time}` : ""}.`);
      push(condition(d));
      return lines.join("\n");
    }
    // Still elevated.
    push(`Still ${level}${d.minutes ? ` after ${d.minutes} minute${d.minutes === 1 ? "" : "s"}` : ""}.`);
    push(condition(d));
    push(confidence(d));
    push(equipment(d));
    const loc = locationLine(event, severe);
    push(loc);
    push(action(level, kind, loc && loc.startsWith("Location:")));
    return lines.join("\n");
  }

  if (kind === "sos") {
    push(d.sos === "noResponse"
      ? `${d.name || "They"} didn't respond to a Critical alert for 60 seconds${d.time ? ` (${d.time})` : ""}.`
      : `${d.name || "They"} pressed Call 911${d.time ? ` at ${d.time}` : ""}.`);
    push(condition(d));
  } else {
    push(condition(d));
    push(confidence(d));
  }
  push(equipment(d));
  const loc = locationLine(event, severe);
  push(loc);
  if (kind !== "sos") push(wearerWasAsked(level));
  push(action(level, kind, loc && loc.startsWith("Location:")));
  push(FOLLOW_UP);
  return lines.join("\n");
}

/// Sent by the relay itself when the wearer's phone goes quiet during an
/// active event.
function composeSilence(state, minutes) {
  const name = state.name || "your contact";
  const lines = [`Thermyx - no update from ${name}`];
  lines.push(`Their phone hasn't sent anything for ${minutes} minutes during a ${state.level} alert. Their phone, signal or insoles may be off.`);
  if (state.location) {
    lines.push(`Last location: https://maps.google.com/?q=${state.location.latitude.toFixed(5)},${state.location.longitude.toFixed(5)}`);
  }
  lines.push("Check on them directly. If you can't reach them, call 911.");
  return lines.join("\n");
}

/// Sent when updates resume after a silence text.
function composeReconnected(event, detail) {
  const d = detail || { unit: "F" };
  const lines = [`Thermyx update - ${d.name || "your contact"}`];
  lines.push(`Their phone is back in touch. Now ${event.level}.`);
  const c = condition(d);
  if (c && event.level !== "Normal") lines.push(c);
  return lines.join("\n");
}

/// A text as a push notification: the first line is the title, the rest the
/// body, without the map link (the watcher's screen has the map) or the
/// sentence about follow-ups. High risk, Critical and SOS break through
/// Focus modes ("time-sensitive"); the rest are ordinary.
function pushFromText(text, urgent) {
  const [title, ...rest] = text.split("\n");
  const body = rest.filter(line => !line.startsWith("Location:") && !line.startsWith("Last location:") && line !== FOLLOW_UP).join(" ");
  return {
    payload: {
      aps: {
        alert: { title, body },
        sound: "default",
        "thread-id": "thermyx-watch",
        "interruption-level": urgent ? "time-sensitive" : "active"
      },
      thermyx: { v: 1 }
    },
    priority: "high",
    ttlSeconds: urgent ? 3600 : 900
  };
}

function composePush(event, detail) {
  const kind = event.kind || "alert";
  const urgent = kind === "sos" || event.level === "High risk" || event.level === "Critical";
  return pushFromText(composeMessage(event, detail), urgent);
}

module.exports = { cleanDetail, composeMessage, composeSilence, composeReconnected, composePush, pushFromText, LEVELS, CAUSES };
