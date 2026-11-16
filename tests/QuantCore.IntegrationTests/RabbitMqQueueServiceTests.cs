using System.Text;
using System.Text.Json;
using QuantCore.Api.Messaging;
using QuantCore.Contracts.Messaging;
using RabbitMQ.Client;
using Testcontainers.RabbitMq;
using Xunit;

namespace QuantCore.IntegrationTests;

public sealed class RabbitMqQueueServiceTests : IAsyncLifetime
{
    private readonly RabbitMqContainer _container = new RabbitMqBuilder().WithImage("rabbitmq:3-management-alpine").Build();
    private IConnection _connection = null!;
    private RabbitMqQueueService _service = null!;

    public async Task InitializeAsync()
    {
        await _container.StartAsync();
        var factory = new ConnectionFactory { Uri = new Uri(_container.GetConnectionString()) };
        _connection = factory.CreateConnection();
        _service = new RabbitMqQueueService(_connection);
    }

    public async Task DisposeAsync()
    {
        _connection.Dispose();
        await _container.DisposeAsync();
    }

    private static InputTaskMessage NewTask() => new(Guid.NewGuid(), TaskCommandType.RECALCULATE_POOL, "P", 0.5m, 1,
        new[] { "BTCUSDT" }, DateTimeOffset.UtcNow);

    private void PublishStatus(OutputStatusMessage status)
    {
        using var channel = _connection.CreateModel();
        channel.BasicPublish("", RabbitMqQueueService.OutputQueueName, null,
            Encoding.UTF8.GetBytes(JsonSerializer.Serialize(status)));
    }

    private static OutputStatusMessage Status(Guid jobId, QueueJobState state) =>
        new(jobId, state, 100m, 0.9m, null, null, DateTimeOffset.UtcNow);

    [Fact]
    public void Submit_Publishes_Task_To_Input_Queue_And_Starting_Status_To_Output_Queue()
    {
        var task = NewTask();

        _service.SubmitTaskToInputQueue(task);

        using var channel = _connection.CreateModel();
        var input = channel.BasicGet(RabbitMqQueueService.InputQueueName, autoAck: true);
        Assert.NotNull(input);
        var received = JsonSerializer.Deserialize<InputTaskMessage>(Encoding.UTF8.GetString(input.Body.ToArray()));
        Assert.Equal(task.JobId, received!.JobId);

        var status = _service.PeekOutputQueueStatus();
        Assert.Equal(task.JobId, status!.JobId);
        Assert.Equal(QueueJobState.STARTING, status.Status);
    }

    [Fact]
    public void Output_Queue_Keeps_Only_The_Newest_Message()
    {
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        PublishStatus(Status(first, QueueJobState.PROCESSING));
        PublishStatus(Status(second, QueueJobState.PROCESSING));

        var head = _service.PeekOutputQueueStatus();

        Assert.Equal(second, head!.JobId);
    }

    [Fact]
    public void Peek_Requeues_Non_Terminal_Status_And_Consumes_Terminal_Status()
    {
        var job = Guid.NewGuid();
        PublishStatus(Status(job, QueueJobState.PROCESSING));

        Assert.Equal(QueueJobState.PROCESSING, _service.PeekOutputQueueStatus()!.Status);
        Assert.Equal(QueueJobState.PROCESSING, _service.PeekOutputQueueStatus()!.Status);

        using (var channel = _connection.CreateModel())
        {
            channel.QueuePurge(RabbitMqQueueService.OutputQueueName);
        }

        PublishStatus(Status(job, QueueJobState.SUCCEEDED));
        Assert.Equal(QueueJobState.SUCCEEDED, _service.PeekOutputQueueStatus()!.Status);
        Assert.Null(_service.PeekOutputQueueStatus());
    }

    [Fact]
    public void Peek_Returns_Null_On_Empty_Queue()
    {
        Assert.Null(_service.PeekOutputQueueStatus());
    }
}
