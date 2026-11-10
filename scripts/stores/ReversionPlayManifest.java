// Uses the official AAPT protobuf classes shipped in the pinned bundletool JAR.
import com.android.aapt.Resources;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.jar.JarFile;

public final class ReversionPlayManifest {
    private static final String ANDROID = "http://schemas.android.com/apk/res/android";

    public static void main(String[] args) throws Exception {
        if (args.length == 3 && args[0].equals("verify-signer")) {
            int verified = 0;
            try (var jar = new JarFile(args[1], true)) {
                var entries = jar.entries();
                while (entries.hasMoreElements()) {
                    var entry = entries.nextElement();
                    if (entry.isDirectory() || entry.getName().matches("(?i)META-INF/(MANIFEST\\.MF|[^/]+\\.(SF|RSA|DSA|EC))")) {
                        continue;
                    }
                    try (var input = jar.getInputStream(entry)) {
                        input.transferTo(java.io.OutputStream.nullOutputStream());
                    }
                    var signers = entry.getCodeSigners();
                    if (signers == null || signers.length != 1) {
                        throw new IllegalArgumentException("Unsigned or unexpected signer count: " + entry.getName());
                    }
                    var cert = signers[0].getSignerCertPath().getCertificates().get(0);
                    var digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(cert.getEncoded()));
                    if (!digest.equals(args[2])) {
                        throw new IllegalArgumentException("Upload signer differs from original release");
                    }
                    verified++;
                }
            }
            if (verified < 1000) throw new IllegalArgumentException("Unexpectedly incomplete bundle");
            System.out.println("Verified original upload signer on " + verified + " payload entries");
            return;
        }
        if (args.length != 2) throw new IllegalArgumentException("Expected input and output manifest");
        var original = Resources.XmlNode.parseFrom(Files.readAllBytes(Path.of(args[0])));
        var element = original.getElement();
        if (!element.getName().equals("manifest")) throw new IllegalArgumentException("Expected manifest root");
        int versionIndex = -1;
        boolean packageMatches = false;
        boolean versionMatches = false;
        for (int i = 0; i < element.getAttributeCount(); i++) {
            var attr = element.getAttribute(i);
            if (attr.getNamespaceUri().isEmpty() && attr.getName().equals("package")) {
                packageMatches = attr.getValue().equals("org.snapetech.pleazyng");
            }
            if (attr.getNamespaceUri().equals(ANDROID) && attr.getName().equals("versionName")) {
                versionMatches = attr.getValue().equals("3.0.7");
            }
            if (attr.getNamespaceUri().equals(ANDROID) && attr.getName().equals("versionCode")) {
                if (versionIndex != -1) throw new IllegalArgumentException("Duplicate version code");
                versionIndex = i;
            }
        }
        if (!packageMatches || !versionMatches || versionIndex < 0) {
            throw new IllegalArgumentException("Expected immutable Pleazyng 3.0.7 identity");
        }
        var oldAttr = element.getAttribute(versionIndex);
        if (!oldAttr.hasCompiledItem() || !oldAttr.getCompiledItem().hasPrim()
                || oldAttr.getCompiledItem().getPrim().getIntDecimalValue() != 166
                || (!oldAttr.getValue().isEmpty() && !oldAttr.getValue().equals("166"))) {
            throw new IllegalArgumentException("Expected original version code166");
        }
        var attr = oldAttr.toBuilder();
        if (!oldAttr.getValue().isEmpty()) attr.setValue("167");
        attr.getCompiledItemBuilder().getPrimBuilder().setIntDecimalValue(167);
        var patched = original.toBuilder().setElement(element.toBuilder().setAttribute(versionIndex, attr)).build();
        var restored = patched.toBuilder().setElement(patched.getElement().toBuilder().setAttribute(versionIndex, oldAttr)).build();
        if (!restored.equals(original)) throw new IllegalStateException("Unexpected manifest mutation");
        Files.write(Path.of(args[1]), patched.toByteArray());
        System.out.println("Changed only Android version code166 to167; package/version name preserved");
    }
}
