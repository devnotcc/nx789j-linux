import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

/** Callback events from the radio HAL (binder threads) -> main thread. */
public final class Ev {
    public final String name;
    public final Object[] args;

    private Ev(String name, Object[] args) { this.name = name; this.args = args; }

    private static final LinkedBlockingQueue<Ev> Q = new LinkedBlockingQueue<>();
    static volatile boolean verbose;

    static void on(String name, Object[] args) {
        if (verbose) {
            StringBuilder b = new StringBuilder("EV ").append(name);
            for (Object a : args) b.append(' ').append(a);
            NxRadio.log(b.toString());
        }
        Q.add(new Ev(name, args));
    }

    /** Next event, or null after timeoutMs. */
    static Ev next(long timeoutMs) throws InterruptedException {
        return Q.poll(timeoutMs, TimeUnit.MILLISECONDS);
    }
}
