export function machineControlsDisabled(inFlight: Record<string, boolean>, machineID: string) {
  return inFlight[machineID] === true;
}
