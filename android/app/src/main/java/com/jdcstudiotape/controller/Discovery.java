package com.jdcstudiotape.controller;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InterfaceAddress;
import java.net.NetworkInterface;
import java.net.SocketTimeoutException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Busca el PC con JDCStudioTape en la Wi-Fi: broadcast UDP "JDC-CONTROLLER?" al puerto 8767 (o a una IP concreta) y
 * recoge las respuestas del PC (Capture/PhoneServer.cs › StartDiscovery): nombre, puertos HTTPS/HTTP, huella de la CA y
 * móviles conectados. La IP es la de quien responde (la que el móvil alcanza de verdad).
 */
final class Discovery {
    static final int PORT = 8767;
    private static final byte[] PROBE = "JDC-CONTROLLER?".getBytes(StandardCharsets.US_ASCII);

    private Discovery() { }

    static JSONArray find(String ip) {
        JSONArray out = run(ip);
        // Router que no deja pasar el broadcast: una a una, las direcciones de la red /24 del móvil.
        if (ip == null && out.length() == 0) out = run("*sweep");
        return out;
    }

    private static JSONArray run(String ip) {
        boolean sweep = "*sweep".equals(ip);
        if (sweep) ip = null;
        JSONArray out = new JSONArray();
        Set<String> seenIp = new HashSet<>(), seenCa = new HashSet<>();
        try (DatagramSocket s = new DatagramSocket()) {
            s.setBroadcast(true);
            s.setSoTimeout(200);
            List<InetAddress> targets = new ArrayList<>();
            if (ip != null) targets.add(InetAddress.getByName(ip));
            else if (sweep) targets.addAll(sweepTargets());
            else {
                targets.add(InetAddress.getByName("255.255.255.255"));
                targets.addAll(interfaceBroadcasts());
            }
            long end = System.currentTimeMillis() + 1800, nextSend = 0;
            int sends = 0;
            byte[] buf = new byte[4096];
            while (System.currentTimeMillis() < end) {
                if (sends < 3 && System.currentTimeMillis() >= nextSend) {
                    for (InetAddress t : targets) {
                        try { s.send(new DatagramPacket(PROBE, PROBE.length, t, PORT)); } catch (Exception ignored) { }
                    }
                    sends++;
                    nextSend = System.currentTimeMillis() + 500;
                }
                DatagramPacket p = new DatagramPacket(buf, buf.length);
                try { s.receive(p); } catch (SocketTimeoutException t) { continue; }
                String from = p.getAddress().getHostAddress();
                if (seenIp.contains(from)) continue;
                try {
                    JSONObject o = new JSONObject(new String(p.getData(), p.getOffset(), p.getLength(), StandardCharsets.UTF_8));
                    if (!"jdc".equals(o.optString("t"))) continue;
                    seenIp.add(from);
                    String ca = o.optString("caSha256", "");
                    if (!ca.isEmpty() && !seenCa.add(ca)) continue; // el mismo PC por dos redes
                    o.put("ip", from);
                    out.put(o);
                } catch (Exception ignored) { }
                if (ip != null && out.length() > 0) break;
            }
        } catch (Exception ignored) {
            // sin Wi-Fi: lista vacía
        }
        return out;
    }

    private static List<InetAddress> sweepTargets() {
        List<InetAddress> list = new ArrayList<>();
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isUp() || ni.isLoopback()) continue;
                for (InterfaceAddress a : ni.getInterfaceAddresses()) {
                    if (!(a.getAddress() instanceof Inet4Address) || a.getBroadcast() == null) continue;
                    byte[] me = a.getAddress().getAddress();
                    for (int h = 1; h <= 254; h++) {
                        if ((me[3] & 0xFF) == h) continue;
                        list.add(InetAddress.getByAddress(new byte[]{me[0], me[1], me[2], (byte) h}));
                    }
                }
            }
        } catch (Exception ignored) { }
        return list;
    }

    /** Direcciones de broadcast de cada red activa (Wi-Fi, punto de acceso del propio móvil…). */
    private static List<InetAddress> interfaceBroadcasts() {
        List<InetAddress> list = new ArrayList<>();
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isUp() || ni.isLoopback()) continue;
                for (InterfaceAddress a : ni.getInterfaceAddresses()) {
                    if (a.getAddress() instanceof Inet4Address && a.getBroadcast() != null) list.add(a.getBroadcast());
                }
            }
        } catch (Exception ignored) { }
        return list;
    }
}
