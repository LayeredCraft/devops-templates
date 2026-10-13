namespace SelfTest.Library;

/// <summary>Minimal library used to validate the pr-build reusable workflow.</summary>
public static class Greeting
{
    public static string For(string name) => $"Hello, {name}.";
}
