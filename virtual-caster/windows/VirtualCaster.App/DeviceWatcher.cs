using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace VirtualCaster.App;

public sealed record DeviceItem(string? Id, string Name);

public sealed record DeviceSnapshot(
    List<DeviceItem> Captures, List<DeviceItem> Renders, string? DefaultCaptureId, string? DefaultRenderId);

/// <summary>
/// Enumera los dispositivos de audio y avisa cuando Windows agrega, quita, habilita o deshabilita uno,
/// o cuando cambia el dispositivo predeterminado. El evento llega en un hilo del sistema, no en el de la interfaz.
/// </summary>
public sealed class DeviceWatcher : IMMNotificationClient, IDisposable
{
    private readonly MMDeviceEnumerator _enumerator = new();

    public event Action? Changed;

    public DeviceWatcher() => _enumerator.RegisterEndpointNotificationCallback(this);

    public DeviceSnapshot Snapshot()
    {
        List<DeviceItem> List(DataFlow flow) => _enumerator
            .EnumerateAudioEndPoints(flow, DeviceState.Active)
            .Select(d => new DeviceItem(d.ID, d.FriendlyName))
            .OrderBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();

        string? Default(DataFlow flow)
        {
            try
            {
                return _enumerator.HasDefaultAudioEndpoint(flow, Role.Console)
                    ? _enumerator.GetDefaultAudioEndpoint(flow, Role.Console).ID
                    : null;
            }
            catch (Exception)
            {
                return null; // puede fallar si el dispositivo desaparece durante la consulta
            }
        }

        return new DeviceSnapshot(List(DataFlow.Capture), List(DataFlow.Render), Default(DataFlow.Capture), Default(DataFlow.Render));
    }

    void IMMNotificationClient.OnDeviceStateChanged(string deviceId, DeviceState newState) => Changed?.Invoke();
    void IMMNotificationClient.OnDeviceAdded(string pwstrDeviceId) => Changed?.Invoke();
    void IMMNotificationClient.OnDeviceRemoved(string deviceId) => Changed?.Invoke();
    void IMMNotificationClient.OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId) => Changed?.Invoke();
    void IMMNotificationClient.OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }

    public void Dispose()
    {
        try { _enumerator.UnregisterEndpointNotificationCallback(this); } catch (Exception) { /* al cerrar */ }
        _enumerator.Dispose();
    }
}
